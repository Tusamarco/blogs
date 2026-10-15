-- =====================================================================
--  Validation and formatting at the door
--  JavaScript functions + a trigger, 
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
CREATE FUNCTION proper_name(t VARCHAR(120))
RETURNS VARCHAR(120)
DETERMINISTIC NO SQL
LANGUAGE JS AS $$
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
CREATE FUNCTION clean_email(t VARCHAR(200))
RETURNS VARCHAR(200)
DETERMINISTIC NO SQL
LANGUAGE JS AS $$
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
CREATE FUNCTION clean_phone(t VARCHAR(60), cc VARCHAR(4))
RETURNS VARCHAR(20)
DETERMINISTIC NO SQL
LANGUAGE JS AS $$
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


-- 1c-bis. WHAT A CHECK CONSTRAINT CAN AND CANNOT DO ABOUT THIS.
--
-- Do NOT say "no CHECK constraint would have caught 'chiamare
-- ufficio'". It is not true, and someone in the room will know it.
-- CHECK accepts REGEXP from 8.0.16, and this catches it:
--
--     ALTER TABLE contacts
--       ADD CONSTRAINT phone_shape
--       CHECK (phone REGEXP '^[-0-9 +()./]{6,}$');
--
-- Measured against the real feed: 51 of the 2,000 phone values contain
-- a letter (28 'chiamare ufficio', 23 'n/a'). That CHECK rejects all
-- 51. It works.
--
-- The real limit is that a CHECK is a PREDICATE, never a TRANSFORM. It
-- can say no; it cannot say "that one is fine, store it like this".
-- Tighten it to the shape you actually want in the column -
--
--     CHECK (phone REGEXP '^\\+[1-9][0-9]{7,14}$')      -- strict E.164
--
-- - and it accepts 226 of 2,000 rows = 11.3%. The other 1,774 are
-- perfectly good Italian phone numbers, typed by humans. A CHECK
-- throws them away; clean_phone() normalises 1,867 of the 1,949
-- non-garbage values into E.164 and rejects the rest.
--
-- Predicate or transform. That is the whole argument, and it survives
-- contact with an expert.
--
-- The query that proves both numbers is in section 1c-ter, below the
-- LOAD DATA - contacts_raw does not exist yet at this point in the
-- script.


-- 1d. IBAN.  ISO 7064 MOD-97-10: move the first four characters to the
--     end, turn every letter into two digits (A=10 .. Z=35), and the
--     whole thing mod 97 must equal 1. An Italian IBAN becomes a
--     30-DIGIT NUMBER.
--
--     HONEST NOTE - READ BEFORE PRESENTING THIS ONE.
--     An earlier version of this file claimed SQL could not do it,
--     because "BIGINT tops out at 19 digits". That claim is FALSE and
--     section 1d-bis below disproves it on this server:
--
--       * DECIMAL holds 65 digits and MOD() on DECIMAL is exact, so the
--         arithmetic is not the problem. Real IBANs reach 45 digits
--         (Malta, the longest letter-heavy format) - well inside 65.
--       * The letter substitution is not the problem either. REPLACE is
--         global and every replacement emits digits only, so 26 nested
--         REPLACE calls convert the whole string at any length, in one
--         expression, in one statement.
--
--     So this is NOT a "SQL cannot" example. It is a readability and
--     maintainability example: compare the two and say so out loud.
--
--     What IS true, and is the real reason for BigInt: a JavaScript
--     Number is an IEEE-754 double, exact only to 2^53-1 (16 digits).
--     Handed a 30-digit value it does not raise - it rounds, and returns
--     the WRONG remainder:
--
--       Number("330542811101000000123456182960") % 97   -> 69   wrong
--       BigInt("330542811101000000123456182960") % 97n  ->  1n  right
--
--     Rounding error 4,896,193,764,016, no warning, no exception. That
--     silence is a JavaScript hazard, not a MySQL one - MySQL raises
--     "BIGINT UNSIGNED value is out of range" in strict mode, loudly.
CREATE FUNCTION valid_iban(t VARCHAR(40))
RETURNS TINYINT
DETERMINISTIC NO SQL
LANGUAGE JS AS $$
  if (t === null) return 0
  const s = t.replace(/\s/g, "").toUpperCase()
  if (!/^[A-Z]{2}\d{2}[A-Z0-9]{10,30}$/.test(s)) return 0
  const moved = s.slice(4) + s.slice(0, 4)
  const digits = moved.replace(/[A-Z]/g, c => (c.charCodeAt(0) - 55).toString())
  return BigInt(digits) % 97n === 1n ? 1 : 0
$$;

SELECT valid_iban('IT17R2562291209992774772147') AS should_be_1,
       valid_iban('IT18R2562291209992774772147') AS should_be_0;


-- 1d-bis. THE SAME CHECK IN PURE SQL.  Run this. It works.
--
-- This is the slide. Not "SQL cannot do it" - "SQL can do it, and here
-- it is." 665 characters of nested REPLACE against six lines of
-- JavaScript, and the SQL version has no name, no tests and no way to
-- fix the alphabet in one place.
WITH t(v) AS (
  SELECT UPPER(REPLACE('IT17 R256 2291 2099 9277 4772 147', ' ', ''))
)
SELECT v,
       MOD(CAST(
         REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
         REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
         REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
         REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
           CONCAT(SUBSTRING(v, 5), SUBSTRING(v, 1, 4))
         ,'A','10'),'B','11'),'C','12'),'D','13'),'E','14'),'F','15'),
          'G','16'),'H','17'),'I','18'),'J','19'),'K','20'),'L','21'),
          'M','22'),'N','23'),'O','24'),'P','25'),'Q','26'),'R','27'),
          'S','28'),'T','29'),'U','30'),'V','31'),'W','32'),'X','33'),
          'Y','34'),'Z','35')
       AS DECIMAL(65,0)), 97) = 1 AS iban_ok
FROM t;
-- +-----------------------------+---------+
-- | v                           | iban_ok |
-- +-----------------------------+---------+
-- | IT17R2562291209992774772147 |       1 |
-- +-----------------------------+---------+
--
-- VERIFIED against IT, MT, GB and DE sample IBANs - all return 1.
--
-- Where the SQL version genuinely runs out:
--   * it validates nothing about SHAPE. valid_iban() rejects a
--     malformed string before computing anything; this returns a
--     remainder for any garbage you feed it.
--   * DECIMAL(65,0) overflows above 65 digits. No real IBAN format
--     gets there (max observed 45), so this is a theoretical limit,
--     not a practical one. Do not claim it on a slide.
--   * it cannot be called by name from a CHECK, a trigger, a JOIN or
--     another query without being copied in full, every time.
--
-- That last one is the actual argument, and it is enough.


-- =====================================================================
-- 2.  ONE FUNCTION THAT DOES THE WHOLE ROW
--     Returns the cleaned values AND a list of what was wrong, so the
--     caller can decide whether to fix, reject or quarantine.
-- =====================================================================

CREATE FUNCTION clean_contact(raw JSON)
RETURNS JSON
DETERMINISTIC NO SQL
LANGUAGE JS AS $$
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
--     A BEFORE INSERT trigger. Nothing gets in unclean, no matter which
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

CREATE TRIGGER contacts_bi BEFORE INSERT ON contacts
FOR EACH ROW
BEGIN
  DECLARE v JSON;
  SET v = clean_contact(JSON_OBJECT('name',  NEW.name,
                                    'email', NEW.email,
                                    'phone', NEW.phone,
                                    'iban',  NEW.iban));

  IF NOT JSON_VALUE(v, '$.ok' RETURNING UNSIGNED) THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'contact rejected';       -- see errors in $.errors
  END IF;

  SET NEW.name  = JSON_UNQUOTE(JSON_EXTRACT(v, '$.name'));
  SET NEW.email = JSON_UNQUOTE(JSON_EXTRACT(v, '$.email'));
  SET NEW.phone = JSON_UNQUOTE(JSON_EXTRACT(v, '$.phone'));
  SET NEW.iban  = JSON_UNQUOTE(JSON_EXTRACT(v, '$.iban'));
END //

DELIMITER ;

-- The door works whoever knocks:
INSERT INTO contacts (name, email, phone, iban)
VALUES ('  giulia   VAN DER berg ', '  GIULIA.VDB@Libero.IT ',
        '011/8130409', 'IT17R2562291209992774772147');

SELECT * FROM contacts\G
--  name  : Giulia van der Berg
--  email : giulia.vdb@libero.it
--  phone : +39118130409
--  iban  : IT17R2562291209992774772147

-- and it refuses the bad one, from any client, forever
INSERT INTO contacts (name, email, phone, iban)
VALUES ('JAMES MCGREGOR', 'james.mcgregor@', 'chiamare ufficio', NULL);
-- ERROR 1644 (45000): contact rejected


-- ---------------------------------------------------------------------
-- 3a. A BUG IN THE TRIGGER ABOVE - fix this before you demo it
--
--     JSON_UNQUOTE(JSON_EXTRACT(v, '$.iban')) does NOT give you SQL NULL
--     when the IBAN is absent. It gives you the four-character STRING
--     'null', because JSON_EXTRACT returns the JSON literal null and
--     JSON_UNQUOTE dutifully unquotes it.
--
--     53 rows in this feed are accepted with no IBAN. All 53 would land
--     in the table with iban = 'null'. Then:
--         WHERE iban IS NULL          finds nothing
--         WHERE iban IS NOT NULL      finds 2,000 rows
--     and the column is quietly useless. Prove it:
-- ---------------------------------------------------------------------

SELECT JSON_UNQUOTE(JSON_EXTRACT(clean_contact(JSON_OBJECT(
         'name','Luca Rossi','email','luca.rossi@libero.it',
         'phone','011/8130409','iban','')), '$.iban'))       AS looks_like_null,
       JSON_UNQUOTE(JSON_EXTRACT(clean_contact(JSON_OBJECT(
         'name','Luca Rossi','email','luca.rossi@libero.it',
         'phone','011/8130409','iban','')), '$.iban')) IS NULL AS is_it_null;
--  looks_like_null = null      is_it_null = 0     <- a string, not NULL

-- The fix - test the JSON type explicitly:
--     SET NEW.iban = IF(JSON_TYPE(JSON_EXTRACT(v,'$.iban')) = 'NULL',
--                       NULL,
--                       JSON_UNQUOTE(JSON_EXTRACT(v,'$.iban')));
--
-- It only bites `iban` here, because that is the only nullable field an
-- accepted row can have - an invalid phone or email rejects the row
-- outright. Which is exactly why it survives casual testing.


-- =====================================================================
-- 3b. "CAN THE TRIGGER WRITE THE BAD ROW TO rejects?"
--
--     The obvious version does not work, and the reason is worth a slide.
--     SIGNAL makes the statement fail; a failed statement is rolled back;
--     and the trigger's INSERT is part of that same statement. So the
--     reject row is created and then destroyed. You get the error and an
--     empty rejects table.
--
--     Three ways out, in increasing order of how much I would trust them.
-- =====================================================================

-- ---------------------------------------------------------------------
-- OPTION 1: log to a NON-TRANSACTIONAL table, so the rollback cannot
--           reach it. This is the version you asked for, and it does
--           work - but only because MyISAM cannot roll back.
-- ---------------------------------------------------------------------

DROP TABLE IF EXISTS rejects_log;
CREATE TABLE rejects_log (
  id        INT AUTO_INCREMENT PRIMARY KEY,
  logged_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  errors    JSON,
  raw       JSON
) ENGINE=MyISAM;              -- deliberately NOT InnoDB

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

-- Prove that the engine choice is what makes it work:
INSERT INTO contacts (name, email, phone, iban)
VALUES ('JAMES MCGREGOR', 'james.mcgregor@', 'chiamare ufficio', NULL);
-- ERROR 1644 (45000): contact rejected

SELECT COUNT(*) AS survived_the_rollback FROM rejects_log;   -- 1
SELECT errors, raw FROM rejects_log\G

--  Now change ENGINE=MyISAM to ENGINE=InnoDB, repeat, and the count is 0.
--  That is the demo. Same trigger, same SIGNAL, different engine.
--
--  What you are buying, and the price:
--    + the caller still gets a hard error - the contract is unchanged
--    + you get a durable record of what was refused and why
--    - the log is outside your transaction, so it cannot be rolled back
--      even when you want it to be (a retried batch double-logs)
--    - triggers do not fire on a replica under row-based replication, so
--      the log exists only on the primary
--    - MyISAM in 2026 is a hard sell in a review meeting


-- ---------------------------------------------------------------------
-- OPTION 2 (recommended): stop making the door SIGNAL. Put a staging
--           table in front, and let a trigger ROUTE each row to either
--           contacts or rejects. Nothing fails, nothing rolls back,
--           everything is InnoDB, and the caller inserts once.
-- ---------------------------------------------------------------------

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

DELIMITER //

CREATE TRIGGER contacts_in_ai AFTER INSERT ON contacts_in
FOR EACH ROW
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

LOAD DATA LOCAL INFILE '/path/to/contacts_raw.csv'
  INTO TABLE contacts_raw FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
  LINES TERMINATED BY '\n' (id, name, email, phone, iban);

SELECT COUNT(*) FROM contacts_raw;      -- 2000


-- 1c-ter. THE CHECK-CONSTRAINT NUMBERS, measured on the real feed.
--         Forward reference from section 1c-bis. This is the slide-17
--         correction: a CHECK does catch the free text. What it cannot
--         do is keep the 1,774 good numbers that are merely badly typed.
SELECT COUNT(*)                                      AS rows_in,
       SUM(phone REGEXP '[A-Za-z]')                  AS free_text,
       SUM(phone REGEXP '^[-0-9 +()./]{6,}$' = 0)  AS loose_check_rejects,
       SUM(phone REGEXP '^\\+[1-9][0-9]{7,14}$')     AS strict_e164_accepts
FROM contacts_raw;
-- +---------+-----------+---------------------+---------------------+
-- | rows_in | free_text | loose_check_rejects | strict_e164_accepts |
-- +---------+-----------+---------------------+---------------------+
-- |    2000 |        51 |                  98 |                 226 |
-- +---------+-----------+---------------------+---------------------+
--
-- free_text 51           = 28 'chiamare ufficio' + 23 'n/a'
-- loose_check_rejects 98 = those 51 plus 47 too short / misshapen.
--                          So yes, a CHECK catches all of them.
-- strict_e164_accepts    = 226 / 2000 = 11.3%. Make the CHECK strict
--                          enough to be worth having and it throws away
--                          1,774 usable numbers.
--
-- clean_phone() turns 1,867 of the 1,949 non-garbage values into valid
-- E.164 and returns NULL for the rest. Predicate versus transform.


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
