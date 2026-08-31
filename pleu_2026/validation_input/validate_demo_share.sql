-- =====================================================================
--  Validation and formatting at the door
--  JavaScript functions + a trigger, in MySQL 9 (MLE)
--
--  THE ARGUMENT:
--    Every application promises to validate its input. Only the database
--    can guarantee it. Put the rules where the data is and they apply to
--    the web app, the mobile app, the nightly import, the CSV somebody
--    loaded by hand at 2am, and the intern with a mysql prompt.
--
--  THE FEED: 2,000 contacts, typed the way humans and legacy systems
--  actually type them:
--      name   "  giulia van der berg  " / "JAMES MCGREGOR"
--      email  "  FIONA.DELUCA@libero.it  " / "sean.vanderberg@"
--      phone  "011/8130409" / "0039021234522" / "+39 05 5437 8587"
--      iban   IT... with a real mod-97 check digit, 10% of them wrong
--
-- =====================================================================

CREATE DATABASE IF NOT EXISTS intake;
USE intake;

DROP TRIGGER  IF EXISTS contacts_bi;
DROP TRIGGER  IF EXISTS contacts_in_ai;
DROP FUNCTION IF EXISTS clean_contact;
DROP FUNCTION IF EXISTS proper_name;
DROP FUNCTION IF EXISTS clean_email;
DROP FUNCTION IF EXISTS clean_phone;
DROP FUNCTION IF EXISTS valid_iban;
DROP TABLE    IF EXISTS contacts;
DROP TABLE    IF EXISTS contacts_raw;
DROP TABLE    IF EXISTS rejects;
DROP TABLE    IF EXISTS rejects_log;
DROP TABLE    IF EXISTS rejects_routed;
DROP TABLE    IF EXISTS contacts_in;


-- =====================================================================
-- 1.  FORMATTING - four things SQL cannot say cleanly
-- =====================================================================

-- 1a. NAMES.  UPPER() and LOWER() are the only case tools SQL has, and
--     neither knows that McDonald has a capital D, that o'brien has a
--     capital B, or that "van der" stays lowercase.
CREATE FUNCTION proper_name(t VARCHAR(120))  RETURNS VARCHAR(120) DETERMINISTIC NO SQL LANGUAGE JS AS $$
  if (t === null) return null
  const PARTICLES = new Set(['van','von','der','den','de','di','del','della',
                             'da','dos','du','la','le','lo','el','bin','ter'])
  const cap = w => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()

  const words = t.trim().toLowerCase().split(/\s+/)
  return words.map((w, i) => {
    if (i > 0 && PARTICLES.has(w)) return w                  // van der berg
    if (w.startsWith("mc") && w.length > 2)                  // mcdonald
      return "Mc" + cap(w.slice(2))
    if (w.startsWith("mac") && w.length > 4)                 // macleod
      return "Mac" + cap(w.slice(3))
    if (w.includes("'"))                                     // o'brien, d'angelo
      return w.split("'").map(cap).join("'")
    if (w.includes("-"))                                     // anne-marie
      return w.split("-").map(cap).join("-")
    return cap(w)
  }).join(" ")
$$;

SELECT proper_name('  giulia   VAN DER berg ') AS a,   -- Giulia van der Berg
       proper_name('JAMES MCGREGOR')           AS b,   -- James McGregor
       proper_name("sean o'brien")             AS c,   -- Sean O'Brien
       proper_name('MACLEOD anne-marie')       AS d;   -- MacLeod Anne-Marie


-- 1b. EMAIL.  Trim, lower-case, and reject what is not an address.
--     Returns NULL when it cannot be salvaged.
CREATE FUNCTION clean_email(t VARCHAR(200)) RETURNS VARCHAR(200) DETERMINISTIC NO SQL LANGUAGE JS AS $$
  if (t === null) return null
  const s = t.trim().toLowerCase()
  // one @, something either side, a dot in the domain, no trailing dot
  if (!/^[^\s@]+@[^\s@.]+(\.[^\s@.]+)+$/.test(s)) return null
  const [local, domain] = s.split("@")
  return local + "@" + domain
$$;

SELECT clean_email('  FIONA.DELUCA@libero.it  ') AS ok,       -- fiona.deluca@libero.it
       clean_email('sean.vanderberg@')           AS no_domain, -- NULL
       clean_email('mario.rossi@@gmail.com')     AS double_at, -- NULL
       clean_email('luca.bianchi@azienda.it.')   AS trailing;  -- NULL


-- 1c. PHONE -> E.164.  Arrives in eight shapes, must be stored in one.
CREATE FUNCTION clean_phone(t VARCHAR(60), cc VARCHAR(4)) RETURNS VARCHAR(20) DETERMINISTIC NO SQL LANGUAGE JS AS $$
  if (t === null) return null
  let s = t.trim().replace(/[\s\-().\/]/g, "")      // strip human decoration
  if (s.startsWith("00")) s = "+" + s.slice(2)      // 0039... -> +39...
  if (/^\d/.test(s) && s.startsWith(cc)) s = "+" + s
  if (!s.startsWith("+")) s = "+" + cc + s.replace(/^0+/, "")
  if (!/^\+\d{8,15}$/.test(s)) return null          // E.164 length rules
  return s
$$;

SELECT clean_phone('011/8130409','39')      AS slashes,   -- +39118130409
       clean_phone('0039021234522','39')    AS intl_00,   -- +39021234522
       clean_phone('+39 05 5437 8587','39') AS spaced,    -- +390554378587
       clean_phone('chiamare ufficio','39') AS rubbish;   -- NULL


-- 1d. IBAN.  A real checksum: move the first four characters to the end,
--     turn every letter into two digits, and the whole thing mod 97 must
--     equal 1. An Italian IBAN becomes a 29-DIGIT NUMBER.
--
--     BIGINT tops out at 19 digits. In SQL you would have to chunk the
--     modulo by hand; JavaScript has BigInt.
CREATE FUNCTION valid_iban(t VARCHAR(40)) RETURNS TINYINT DETERMINISTIC NO SQL LANGUAGE JS AS $$
  if (t === null) return 0
  const s = t.replace(/\s/g, "").toUpperCase()
  if (!/^[A-Z]{2}\d{2}[A-Z0-9]{10,30}$/.test(s)) return 0
  const moved = s.slice(4) + s.slice(0, 4)
  const digits = moved.replace(/[A-Z]/g, c => (c.charCodeAt(0) - 55).toString())
  return BigInt(digits) % 97n === 1n ? 1 : 0
$$;

SELECT valid_iban('IT17R2562291209992774772147') AS should_be_1,
       valid_iban('IT18R2562291209992774772147') AS should_be_0;


-- =====================================================================
-- 2.  ONE FUNCTION THAT DOES THE WHOLE ROW
--     Returns the cleaned values AND a list of what was wrong, so the
--     caller can decide whether to fix, reject or quarantine.
-- =====================================================================

CREATE FUNCTION clean_contact(raw JSON) RETURNS JSON DETERMINISTIC NO SQL LANGUAGE JS AS $$
  const r = typeof raw === 'string' ? JSON.parse(raw) : raw
  const errors = []

  const PARTICLES = new Set(['van','von','der','den','de','di','del','della',
                             'da','dos','du','la','le','lo','el','bin','ter'])
  const cap = w => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()
  const properName = t => t.trim().toLowerCase().split(/\s+/).map((w, i) =>
      (i > 0 && PARTICLES.has(w)) ? w
    : (w.startsWith("mc") && w.length > 2)  ? "Mc" + cap(w.slice(2))
    : (w.startsWith("mac") && w.length > 4) ? "Mac" + cap(w.slice(3))
    : w.includes("'") ? w.split("'").map(cap).join("'")
    : w.includes("-") ? w.split("-").map(cap).join("-")
    : cap(w)).join(" ")

  const name = (r.name && r.name.trim()) ? properName(r.name) : null
  if (!name) errors.push("name missing")

  let email = (r.email || "").trim().toLowerCase()
  if (!/^[^\s@]+@[^\s@.]+(\.[^\s@.]+)+$/.test(email)) { errors.push("email invalid"); email = null }

  let phone = (r.phone || "").trim().replace(/[\s\-().\/]/g, "")
  if (phone.startsWith("00")) phone = "+" + phone.slice(2)
  if (/^\d/.test(phone) && phone.startsWith("39")) phone = "+" + phone
  if (phone && !phone.startsWith("+")) phone = "+39" + phone.replace(/^0+/, "")
  if (!/^\+\d{8,15}$/.test(phone)) { errors.push("phone invalid"); phone = null }

  let iban = (r.iban || "").replace(/\s/g, "").toUpperCase()
  if (!iban) { iban = null }
  else if (!/^[A-Z]{2}\d{2}[A-Z0-9]{10,30}$/.test(iban)) { errors.push("iban malformed"); iban = null }
  else {
    const moved = iban.slice(4) + iban.slice(0, 4)
    const digits = moved.replace(/[A-Z]/g, c => (c.charCodeAt(0) - 55).toString())
    if (BigInt(digits) % 97n !== 1n) { errors.push("iban checksum failed"); iban = null }
  }

  return { ok: errors.length === 0, errors, name, email, phone, iban }
$$;

SELECT JSON_PRETTY(clean_contact(JSON_OBJECT(
  'name','  giulia   VAN DER berg ', 'email','  GIULIA.VDB@Libero.IT ',
  'phone','011/8130409', 'iban','IT17R2562291209992774772147'))) AS good\G

SELECT JSON_PRETTY(clean_contact(JSON_OBJECT(
  'name','JAMES MCGREGOR', 'email','james.mcgregor@',
  'phone','chiamare ufficio', 'iban','IT18R2562291209992774772147'))) AS bad\G


-- =====================================================================
-- 3.  THE DOOR ITSELF
--     Nothing gets in unclean, no matter which
--     application, script or human is doing the inserting.
-- =====================================================================

CREATE TABLE contacts (
  id    INT AUTO_INCREMENT PRIMARY KEY,
  name  VARCHAR(120) NOT NULL,
  email VARCHAR(200) NOT NULL,
  phone VARCHAR(20)  NULL,
  iban  VARCHAR(40)  NULL,
  UNIQUE KEY uq_email (email)
) ENGINE=InnoDB;

DELIMITER //


DROP TABLE IF EXISTS contacts_in;
CREATE TABLE contacts_in (            -- the door everybody knocks on
  id    INT AUTO_INCREMENT PRIMARY KEY,
  name  VARCHAR(120), email VARCHAR(200),
  phone VARCHAR(60),  iban  VARCHAR(40)
) ENGINE=InnoDB;

-- its own reject table, so this section does not collide with the
-- bulk-load `rejects` table built in 4c
DROP TABLE IF EXISTS rejects_routed;
CREATE TABLE rejects_routed (
  id     INT AUTO_INCREMENT PRIMARY KEY,
  src_id INT NOT NULL,                  -- contacts_in.id it came from
  errors JSON,
  raw    JSON
) ENGINE=InnoDB;



-- [Optional] Use the BEFORE Trigger if you want a safe check in case of some direct request and not want to log error

DROP TRIGGER IF EXISTS contacts_bi;
DELIMITER //

CREATE TRIGGER contacts_bi BEFORE INSERT ON contacts
FOR EACH ROW
BEGIN
  DECLARE v JSON;
  SET v = clean_contact(JSON_OBJECT('name',  NEW.name,
                                    'email', NEW.email,
                                    'phone', NEW.phone,
                                    'iban',  NEW.iban));

  IF NOT JSON_VALUE(v, '$.ok' RETURNING UNSIGNED) THEN
    INSERT INTO rejects_log (errors, raw)
    VALUES (JSON_EXTRACT(v, '$.errors'),
            JSON_OBJECT('name',  NEW.name, 'email', NEW.email,
                        'phone', NEW.phone, 'iban',  NEW.iban));
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'contact rejected';
  END IF;

  SET NEW.name  = JSON_UNQUOTE(JSON_EXTRACT(v, '$.name'));
  SET NEW.email = JSON_UNQUOTE(JSON_EXTRACT(v, '$.email'));
  SET NEW.phone = JSON_UNQUOTE(JSON_EXTRACT(v, '$.phone'));
  SET NEW.iban  = IF(JSON_TYPE(JSON_EXTRACT(v,'$.iban')) = 'NULL', NULL,
                     JSON_UNQUOTE(JSON_EXTRACT(v,'$.iban')));
END //

DELIMITER ;
-- [Optional - END]

DELIMITER //

CREATE TRIGGER contacts_in_ai AFTER INSERT ON contacts_in FOR EACH ROW
BEGIN
  DECLARE v   JSON;
  DECLARE dup TINYINT DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR 1062 SET dup = 1;   -- duplicate email

  SET v = clean_contact(JSON_OBJECT('name',  NEW.name,
                                    'email', NEW.email,
                                    'phone', NEW.phone,
                                    'iban',  NEW.iban));

  IF JSON_VALUE(v, '$.ok' RETURNING UNSIGNED) THEN
    INSERT INTO contacts (name, email, phone, iban)
    VALUES (JSON_UNQUOTE(JSON_EXTRACT(v, '$.name')),
            JSON_UNQUOTE(JSON_EXTRACT(v, '$.email')),
            JSON_UNQUOTE(JSON_EXTRACT(v, '$.phone')),
            IF(JSON_TYPE(JSON_EXTRACT(v,'$.iban')) = 'NULL', NULL,
               JSON_UNQUOTE(JSON_EXTRACT(v,'$.iban'))));

    IF dup = 1 THEN                                -- clean, but already here
      INSERT INTO rejects_routed (src_id, errors, raw)
      VALUES (NEW.id, JSON_ARRAY('duplicate email'),
              JSON_OBJECT('name',  NEW.name, 'email', NEW.email,
                          'phone', NEW.phone, 'iban',  NEW.iban));
    END IF;
  ELSE
    INSERT INTO rejects_routed (src_id, errors, raw)
    VALUES (NEW.id, JSON_EXTRACT(v, '$.errors'),
            JSON_OBJECT('name',  NEW.name, 'email', NEW.email,
                        'phone', NEW.phone, 'iban',  NEW.iban));
  END IF;
END //

DELIMITER ;

-- One insert, two destinations, no error:
INSERT INTO contacts_in (name, email, phone, iban) VALUES
  ('  giulia   VAN DER berg ','  GIULIA.VDB@Libero.IT ','011/8130409',
   'IT17R2562291209992774772147'),
  ('JAMES MCGREGOR','james.mcgregor@','chiamare ufficio', NULL);

SELECT id, name, email, phone, iban FROM contacts;
SELECT src_id, errors FROM rejects_routed;
--  contacts : Giulia van der Berg   giulia.vdb@libero.it   +39118130409
--  rejects  : ["email invalid", "phone invalid"]
--
--  Note the CONTINUE HANDLER for 1062: a row can be perfectly clean and
--  still not belong in the table, because the email is already there.
--  "Invalid" and "unwanted" are different verdicts and a real intake
--  path needs both. That handler is where most homegrown loaders break.
--
--  Note also what did NOT go away: contacts keeps its own BEFORE INSERT
--  trigger. The staging table is a convenience for callers; the trigger
--  on contacts is the guarantee. Anyone who inserts into contacts
--  directly still cannot get a bad row in. Defence in depth - the
--  routing layer is allowed to be bypassed, the door is not.


-- ---------------------------------------------------------------------
-- OPTION 3: for a bulk load, do not use a trigger at all. Section 4c
--           already does this - one set-based statement for the good
--           rows, one for the rejects. No row-at-a-time anything, and
--           it is by far the fastest of the three.
--
--           Rule of thumb: trigger for interactive traffic where you
--           want a hard error, set-based for imports where you want a
--           report. Same JavaScript function underneath both.
-- ---------------------------------------------------------------------


-- =====================================================================
-- 4.  THE WHOLE FEED
--     2,000 rows as they actually arrived (contacts_raw.csv).
--     local_infile must be on at both ends:
--        server : SET GLOBAL local_infile = 1;
--        client : mysql --local-infile=1 ...
-- =====================================================================

CREATE TABLE contacts_raw (
  id    INT PRIMARY KEY,
  name  VARCHAR(120),
  email VARCHAR(200),
  phone VARCHAR(60),
  iban  VARCHAR(40)
) ENGINE=InnoDB;

LOAD DATA INFILE '/media/psf/Home/work/mysql/Conferences/2026/pleu/javascript_2026/validation_input/contacts_raw.csv'
  INTO TABLE contacts_raw FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
  LINES TERMINATED BY '\n' (id, name, email, phone, iban);

SELECT COUNT(*) FROM contacts_raw;      -- 2000

-- 4a. Triage the whole feed in one statement. Nothing is written yet,
--     nothing has left the server, and now you know exactly what you got.
SELECT COUNT(*)                                             AS rows_in,
       SUM(v.ok)                                            AS clean,
       SUM(NOT v.ok)                                        AS rejected,
       SUM(JSON_CONTAINS(v.errs, '"email invalid"'))        AS bad_email,
       SUM(JSON_CONTAINS(v.errs, '"phone invalid"'))        AS bad_phone,
       SUM(JSON_CONTAINS(v.errs, '"iban checksum failed"')) AS bad_iban
FROM (
  SELECT JSON_VALUE(c, '$.ok' RETURNING UNSIGNED) AS ok,
         JSON_EXTRACT(c, '$.errors')              AS errs
  FROM (SELECT clean_contact(JSON_OBJECT('name',name,'email',email,
                                         'phone',phone,'iban',iban)) AS c
        FROM contacts_raw) x
) v;

--  Measured on the supplied file - these are exact, not approximate:
--    rows_in 2000   clean 1540   rejected 460
--    bad_email 160   bad_phone 133   bad_iban 195
--
--  Note 160 + 133 + 195 = 488 errors across only 460 rejected rows:
--  28 rows are wrong in two ways at once. That is why clean_contact
--  returns an ARRAY of errors rather than the first one it hits - a
--  validator that stops at the first failure makes a human re-submit
--  the same row twice.
--
--  Two error types never fire on this feed, so do not promise them on
--  a slide: 'name missing' (every row has a name) and 'iban malformed'
--  (the blank IBANs are treated as absent, not invalid - an optional
--  field left empty is not an error, and that distinction matters).

-- 4b. What the reformatting actually did
SELECT r.name  AS name_in,   JSON_UNQUOTE(JSON_EXTRACT(c,'$.name'))  AS name_out,
       r.phone AS phone_in,  JSON_UNQUOTE(JSON_EXTRACT(c,'$.phone')) AS phone_out
FROM contacts_raw r
JOIN LATERAL (SELECT clean_contact(JSON_OBJECT('name',r.name,'email',r.email,
                                               'phone',r.phone,'iban',r.iban)) AS c) j
WHERE JSON_VALUE(c,'$.ok' RETURNING UNSIGNED) = 1
LIMIT 15;

-- 4c. Load the good ones, quarantine the rest
CREATE TABLE rejects (
  id     INT PRIMARY KEY,
  errors JSON,
  raw    JSON
) ENGINE=InnoDB;

INSERT INTO rejects (id, errors, raw)
SELECT r.id, JSON_EXTRACT(c,'$.errors'),
       JSON_OBJECT('name',r.name,'email',r.email,'phone',r.phone,'iban',r.iban)
FROM contacts_raw r
JOIN LATERAL (SELECT clean_contact(JSON_OBJECT('name',r.name,'email',r.email,
                                               'phone',r.phone,'iban',r.iban)) AS c) j
WHERE JSON_VALUE(c,'$.ok' RETURNING UNSIGNED) = 0;

SELECT e.err, COUNT(*) AS n
FROM rejects, JSON_TABLE(errors, '$[*]' COLUMNS (err VARCHAR(40) PATH '$')) e
GROUP BY e.err ORDER BY n DESC;


-- =====================================================================
-- 5.  WHY THIS BELONGS IN THE DATABASE
--
--   * The rules are written ONCE. The web app, the mobile app, the
--     nightly import and the person with a mysql prompt all get them.
--     Validation in five applications is five subtly different rulesets
--     and four of them are out of date.
--
--   * A trigger cannot be bypassed. Application validation can be, and
--     eventually is - by the migration script nobody reviewed.
--
--   * Nothing crossed the network to be checked. No round trip per row,
--     no personal data sitting in an app server's memory while it
--     decides whether an email address is well formed.
--
--   * The data is clean at rest, so every query downstream gets simpler:
--     no LOWER(email) in the WHERE clause, no five phone formats to
--     match, and the UNIQUE KEY on email actually means something.
--
--  Two things to say before someone else does:
--
--   * MySQL will NOT let a stored function appear in a CHECK constraint
--     or a generated column. A BEFORE trigger is the mechanism.
--
--   * A trigger that rejects rows is a policy decision. On a bulk import
--     you usually want section 4c instead - load the good, quarantine
--     the bad, and let a human look at the rejects table.
-- =====================================================================
