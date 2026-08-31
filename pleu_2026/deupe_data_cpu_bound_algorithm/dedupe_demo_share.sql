-- =====================================================================
--  "Is this the same customer?"
--  Levenshtein edit distance as a JavaScript function in MySQL 9 (MLE)
--
--  THE SITUATION: you have acquired a company. Their customer list has
--  no key in common with yours. The same people appear in both, typed
--  by different humans on different days.
--
--  THE QUESTION: which of the 2,000 incoming signups are customers we
--  already have?
--
--  Everyone has lived this. It is the oldest data problem there is, and
--  MySQL has no edit-distance function of any kind.
--
-- =====================================================================

CREATE DATABASE IF NOT EXISTS dedupe;
USE dedupe;

DROP FUNCTION IF EXISTS lev_distance;
DROP FUNCTION IF EXISTS lev_ratio;
DROP TABLE    IF EXISTS signups;
DROP TABLE    IF EXISTS customers;


-- =====================================================================
-- 1.  THE FUNCTION
--
--     Levenshtein: the smallest number of single-character insertions,
--     deletions or substitutions that turn one string into the other.
--       "Rossi" -> "Rosi"    = 1   (one deletion)
--       "Marco" -> "Mrako"   = 2   (two swaps)
--
--     It needs a 2-D matrix. The procedural SQL language has no arrays
--     at all, so this is not "slower in PL" - it is not expressible.
-- =====================================================================

CREATE FUNCTION lev_distance(s VARCHAR(255), t VARCHAR(255))
RETURNS INT
DETERMINISTIC NO SQL
LANGUAGE JS AS $$
  if (s === null || t === null) return null
  if (s === t) return 0
  if (!s.length) return t.length
  if (!t.length) return s.length

  // two rolling rows instead of the full matrix:
  // same answer, O(min) memory instead of O(n*m)
  let prev = new Array(t.length + 1)
  let cur  = new Array(t.length + 1)
  for (let j = 0; j <= t.length; j++) prev[j] = j

  for (let i = 1; i <= s.length; i++) {
    cur[0] = i
    const ci = s[i - 1]
    for (let j = 1; j <= t.length; j++) {
      cur[j] = ci === t[j - 1]
             ? prev[j - 1]
             : 1 + Math.min(prev[j], cur[j - 1], prev[j - 1])
    }
    const tmp = prev; prev = cur; cur = tmp
  }
  return prev[t.length]
$$;

-- Distance alone is length-dependent: 2 edits in "Li" is a different
-- thing from 2 edits in "Papadopoulos". This turns it into a percentage.
CREATE FUNCTION lev_ratio(s VARCHAR(255), t VARCHAR(255))
RETURNS DECIMAL(5,2)
DETERMINISTIC NO SQL
LANGUAGE JS AS $$
  if (s === null || t === null) return null
  const n = Math.max(s.length, t.length)
  if (n === 0) return 100.00
  let prev = new Array(t.length + 1), cur = new Array(t.length + 1)
  for (let j = 0; j <= t.length; j++) prev[j] = j
  for (let i = 1; i <= s.length; i++) {
    cur[0] = i
    const ci = s[i - 1]
    for (let j = 1; j <= t.length; j++)
      cur[j] = ci === t[j - 1] ? prev[j - 1]
             : 1 + Math.min(prev[j], cur[j - 1], prev[j - 1])
    const tmp = prev; prev = cur; cur = tmp
  }
  return Math.round((1 - prev[t.length] / n) * 10000) / 100
$$;

SELECT lev_distance('Rossi','Rosi')            AS one_deletion,      -- 1
       lev_distance('Marco Rossi','Mrako Rosi') AS three_edits,      -- 3
       lev_distance('Müller','Muller')          AS accent_dropped,   -- 1
       lev_ratio('Papadopoulos','Papadopulos')  AS pct_similar;      -- ~92


-- =====================================================================
-- 2.  THE DATA  
-- =====================================================================

CREATE TABLE customers (            -- our CRM master
  id    INT PRIMARY KEY,
  name  VARCHAR(80) NOT NULL,
  email VARCHAR(120) NOT NULL,
  city  VARCHAR(40) NOT NULL,
  KEY ix_block (city, name(1))
) ENGINE=InnoDB;

CREATE TABLE signups (              -- the list we just acquired
  id            INT PRIMARY KEY,
  name          VARCHAR(80) NOT NULL,
  email         VARCHAR(120) NOT NULL,
  city          VARCHAR(40) NOT NULL,
  true_match_id INT NOT NULL,       -- ANSWER KEY: the customers.id this signup
                                    -- really is. 0 = not one of our customers.
                                    -- It points at customers.id, never signups.id.
  kind          VARCHAR(8) NOT NULL,-- why this row exists:
                                    --   'dup'  same person, typed badly  (id > 0)
                                    --   'trap' DIFFERENT person, similar name (0)
                                    --   'new'  genuinely new customer        (0)
  KEY ix_block (city, name(1))
) ENGINE=InnoDB;

LOAD DATA INFILE '/path/to/customers.csv'
  INTO TABLE customers FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n'
  (id, name, email, city);

LOAD DATA INFILE '/path/to/signups.csv'
  INTO TABLE signups FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n'
  (id, name, email, city, true_match_id, kind);

-- What is in the feed, and what the answer key says about it.
SELECT kind,
       COUNT(*)                            AS entries,
       SUM(true_match_id > 0)              AS with_a_match,
       SUM(true_match_id = 0)              AS labelled_zero
FROM signups GROUP BY kind ORDER BY kind;

--   kind   rows   with_a_match   labelled_zero
--   dup    1200           1200               0     <- same person, typed badly
--   new     550              0             550     <- genuinely new
--   trap    250              0             250     <- DIFFERENT person, similar name
--
--  NOTE: true_match_id = 0 is 800 rows, not 250. It means "not one of our
--  customers" and covers BOTH the 250 traps and the 550 new. Use `kind` when
--  you want to talk about the traps specifically.

-- entries breakdown
(root@localhost) [dedupe]>select "all entries" as kind, count(*) as count from signups union  SELECT  ' all dup' AS kind,  COUNT(s.id) AS count  FROM signups s  LEFT JOIN customers c ON c.id = s.true_match_id  WHERE c.name IS NOT NULL  UNION  SELECT  '   matching dup' AS kind, COUNT(s.id) AS count  FROM signups s  LEFT JOIN customers c ON c.name = s.name  WHERE c.name IS NOT NULL UNION SELECT  '   not matching dup' AS kind, COUNT(s.id) AS count  FROM signups s  LEFT JOIN customers c ON c.name = s.name  WHERE c.name IS  NULL and kind not in ('new',"trap") union SELECT  ' injected hard negatives' AS kind, COUNT(s.id) AS count  FROM signups s  LEFT JOIN customers c ON c.name = s.name  WHERE c.name IS  NULL and kind ='trap'  union SELECT  ' new customers' AS kind, COUNT(s.id) AS count  FROM  signups s  LEFT JOIN customers c ON c.name = s.name  WHERE c.name IS  NULL and kind ='new'  ;
+--------------------------+-------+
| kind                     | count |
+--------------------------+-------+
| all entries              |  2000 |
|  all dup                 |  1200 |
|    matching dup          |   261 |
|    not matching dup      |   939 |
|  injected hard negatives |   250 |
|  new customers           |   550 |
+--------------------------+-------+
6 rows in set (0.01 sec)

-- How to get traps entries close to customers
SELECT s.id                                  AS trap_id,
       s.name                                AS trap_name,
       c.id                                  AS looks_like,
       c.name                                AS customer_name,
       s.city,
       lev_distance(s.name, c.name)          AS name_dist,
       lev_distance(SUBSTRING_INDEX(s.email,'@',1),
                    SUBSTRING_INDEX(c.email,'@',1)) AS email_dist,
       s.email                               AS trap_email,
       c.email                               AS customer_email
FROM (SELECT * FROM signups WHERE kind = 'trap') s
JOIN customers c
  ON c.city = s.city
WHERE lev_distance(s.name, c.name) BETWEEN 1 AND 2
ORDER BY name_dist, s.id
LIMIT 25;

+---------+-------------------+------------+-------------------+-----------+-----------+------------+---------------------------+-----------------------------+
| trap_id | trap_name         | looks_like | customer_name     | city      | name_dist | email_dist | trap_email                | customer_email              |
+---------+-------------------+------------+-------------------+-----------+-----------+------------+---------------------------+-----------------------------+
|      32 | Lucía Andersen    |       1220 | Luca Andersen     | Padova    |         1 |          8 | andersenl46@fastwebnet.it | luca.andersen@gmail.com     |
|      73 | Sabine Ferrari    |       1043 | Sabine Ferrara    | Hamburg   |         1 |          9 | sferrari35@icloud.com     | sabine.ferrara@yahoo.it     |
|      75 | Elena Schmidt     |       1728 | Eleni Schmidt     | Hamburg   |         1 |          7 | eschmidt85@tiscali.it     | eleni.schmidt@outlook.com   |
|      82 | Roberto Lombardo  |       1938 | Roberto Lombardi  | München   |         1 |         12 | lombardor60@tiscali.it    | roberto.lombardi@gmail.com  |
|      85 | Camille Novak     |       2666 | Camille Nowak     | Torino    |         1 |         10 | cnovak32@gmx.de           | camille.nowak@yahoo.it      |
|      87 | Luca Ruiz         |       1689 | Lucía Ruiz        | Dublin    |         1 |          6 | luca719@tiscali.it        | lucia.ruiz@yahoo.it         |
|      97 | Eleni De Luca     |        897 | Elena De Luca     | Padova    |         1 |          9 | delucae71@fastwebnet.it   | elena.deluca@yahoo.it       |
|      99 | Lucía Bonnet      |       2237 | Luca Bonnet       | Palermo   |         1 |          8 | bonnetl96@orange.fr       | luca.bonnet@yahoo.it        |
|     105 | Nikos Nowak       |       1666 | Nikos Novak       | Venezia   |         1 |          6 | nikos539@orange.fr        | nikos.novak@company.eu      |
|     112 | Michela Conti     |        255 | Michela Conte     | Palermo   |         1 |         10 | mconti26@icloud.com       | michela.conte@libero.it     |
|     142 | Silvia Ferrara    |        792 | Silvia Ferrari    | Roma      |         1 |          9 | sferrara74@orange.fr      | silvia.ferrari@company.eu   |
|     183 | Andrea Lombardo   |        849 | Andrea Lombardi   | Venezia   |         1 |          9 | andrea396@icloud.com      | andrea.lombardi@yahoo.it    |
|     215 | Elena Jiménez     |        736 | Eleni Jiménez     | Firenze   |         1 |          8 | jimenez.e@fastwebnet.it   | eleni.jimenez@outlook.com   |
|     222 | Luca Galli        |        774 | Luca Gallo        | Padova    |         1 |          7 | lgalli43@fastwebnet.it    | luca.gallo@outlook.com      |
|     225 | Elena Braun       |         15 | Eleni Braun       | Dublin    |         1 |          9 | braune86@fastwebnet.it    | eleni.braun@company.eu      |
|     242 | Michela Lombardi  |       1381 | Michela Lombardo  | Firenze   |         1 |          9 | michela534@gmx.de         | michela.lombardo@gmail.com  |
|     275 | Sabine Novak      |        158 | Sabine Nowak      | Barcelona |         1 |          9 | snovak59@tiscali.it       | sabine.nowak@company.eu     |
|     278 | Francesca Conte   |        688 | Francesca Conti   | Napoli    |         1 |         12 | conte.f@orange.fr         | francesca.conti@yahoo.it    |
|     282 | Emanuele Lombardi |        162 | Emanuele Lombardo | Paris     |         1 |         12 | lombardi.e@fastwebnet.it  | emanuele.lombardo@yahoo.it  |
|     319 | Astrid Conte      |       1924 | Astrid Conti      | Dublin    |         1 |          9 | aconte71@tiscali.it       | astrid.conti@proton.me      |
|     348 | Eleni Wolf        |        895 | Elena Wolf        | Roma      |         1 |          9 | wolfe59@gmx.de            | elena.wolf@libero.it        |
|     373 | Elena Esposito    |       2764 | Eleni Esposito    | Genova    |         1 |         10 | elena588@icloud.com       | eleni.esposito@yahoo.it     |
|     403 | Beatrice Ferrari  |       1409 | Beatrice Ferrara  | Hamburg   |         1 |         11 | bferrari68@orange.fr      | beatrice.ferrara@company.eu |
|     418 | Sean Ferrari      |         31 | Sean Ferrara      | Roma      |         1 |          8 | ferrari.s@icloud.com      | sean.ferrara@gmail.com      |
|     423 | Luca Barbieri     |         57 | Lucía Barbieri    | Lyon      |         1 |          9 | barbieril88@fastwebnet.it | lucia.barbieri@outlook.com  |
+---------+-------------------+------------+-------------------+-----------+-----------+------------+---------------------------+-----------------------------+

-- HOW TO GET The real matches using names and emails:
-- Tune the name_dist and email_dist to relax or tight the research
WITH pairs AS (
  SELECT s.true_match_id, c.id AS customer_id, s.id AS signup_id, s.kind,
         s.name AS signup_name, c.name AS customer_name,
         s.email AS signup_email, c.email AS customer_email,
         lev_distance(s.name, c.name) AS name_dist,
         lev_distance(SUBSTRING_INDEX(s.email,'@',1),
                      SUBSTRING_INDEX(c.email,'@',1)) AS email_dist
  FROM signups s
  JOIN customers c
    ON c.city = s.city
   AND (   SUBSTRING_INDEX(c.name,' ',-1) LIKE CONCAT(LEFT(SUBSTRING_INDEX(s.name,' ',-1),1),'%')
        OR SUBSTRING_INDEX(c.name,' ', 1) LIKE CONCAT(LEFT(SUBSTRING_INDEX(s.name,' ', 1),1),'%') )
)
SELECT *, IF(customer_id = true_match_id, 'correct', 'WRONG PAIR') AS verdict
FROM pairs
WHERE name_dist BETWEEN 1 AND 3
  AND email_dist <= 2
ORDER BY name_dist DESC, email_dist DESC;

-- version 2
SELECT s.true_match_id,c.id,s.id,s.kind, s.name AS signup_name,
    c.name AS customer_name, s.email, c.email,
    lev_distance(s.name, c.name) AS name_dist, 
    lev_distance(SUBSTRING_INDEX(s.email,'@',1), SUBSTRING_INDEX(c.email,'@',1)) AS email_dist
FROM signups s 
    JOIN customers c ON c.city = s.city 
    AND LEFT(REPLACE(c.name,' ',''),1) = LEFT(REPLACE(s.name,' ',''),1)
    AND LEFT(REPLACE(c.email,' ',''),1) = LEFT(REPLACE(s.email,' ',''),1)
WHERE lev_distance(s.name, c.name) between 1 and 2 AND lev_distance(SUBSTRING_INDEX(s.email,'@',1),
    SUBSTRING_INDEX(c.email,'@',1)) <= 2
ORDER BY name_dist DESC, email_dist DESC;

-- version 2 no email
SELECT s.true_match_id,c.id,s.id,s.kind, s.name AS signup_name,
    c.name AS customer_name, s.email, c.email,
    lev_distance(s.name, c.name) AS name_dist, 
    lev_distance(SUBSTRING_INDEX(s.email,'@',1), SUBSTRING_INDEX(c.email,'@',1)) AS email_dist
FROM signups s 
    JOIN customers c ON c.city = s.city 
    AND LEFT(REPLACE(c.name,' ',''),1) = LEFT(REPLACE(s.name,' ',''),1)
    AND LEFT(REPLACE(c.email,' ',''),1) = LEFT(REPLACE(s.email,' ',''),1)
WHERE lev_distance(s.name, c.name) between 1 and 1 
ORDER BY name_dist DESC, email_dist DESC;

SELECT s.kind,count(s.name) AS signup_name
FROM signups s 
    JOIN customers c ON c.city = s.city 
    AND LEFT(REPLACE(c.name,' ',''),1) = LEFT(REPLACE(s.name,' ',''),1)
    AND LEFT(REPLACE(c.email,' ',''),1) = LEFT(REPLACE(s.email,' ',''),1)
WHERE lev_distance(s.name, c.name) between 1 and 1 
    group by s.kind;






-- find mismatch 
SELECT s.name AS signup_name, count(s.name) as mismatch
FROM signups s 
    JOIN customers c ON c.city = s.city 
    AND LEFT(REPLACE(c.name,' ',''),1) = LEFT(REPLACE(s.name,' ',''),1)
    AND LEFT(REPLACE(c.email,' ',''),1) = LEFT(REPLACE(s.email,' ',''),1)
WHERE lev_distance(s.name, c.name) between 1 and 4 AND lev_distance(SUBSTRING_INDEX(s.email,'@',1),
    SUBSTRING_INDEX(c.email,'@',1)) <= 2
    group by  signup_name having  mismatch > 1;

--mismatch no email
SELECT s.name AS signup_name, count(s.name) as mismatch
FROM signups s 
    JOIN customers c ON c.city = s.city 
    AND LEFT(REPLACE(c.name,' ',''),1) = LEFT(REPLACE(s.name,' ',''),1)
    AND LEFT(REPLACE(c.email,' ',''),1) = LEFT(REPLACE(s.email,' ',''),1)
WHERE lev_distance(s.name, c.name) between 1 and 2
    group by  signup_name having  mismatch > 1;


+------------------+----------+
| signup_name      | mismatch |
+------------------+----------+
| Laura Rosssi     |        2 |
| Antonuo Lopez    |        2 |
| Alessandro Cotne |        2 |
| Mraia Dubo is    |        2 |
| Lura Bonnet      |        2 |
| Laura Bisnco     |        2 |
| Roco B raun      |        2 |
| Lauar DeSantis   |        2 |
| Sabine Cnoti     |        2 |
| Lqura Villa      |        2 |
| Rocío Bru no     |        2 |
+------------------+----------+
11 rows in set (0.63 sec)




-- How to see when things do not matches with dulicate and you want to find the duplicate
(root@localhost) [dedupe]>select s.kind, c.id,s.true_match_id, c.name,s.name,c.email,s.email from customers c join signups s on c.id = s.true_match_id where s.true_match_id = 1118;
+------+------+---------------+-------------+--------------+-----------------------+-----------------------+
| kind | id   | true_match_id | name        | name         | email                 | email                 |
+------+------+---------------+-------------+--------------+-----------------------+-----------------------+
| dup  | 1118 |          1118 | Laura Rossi | Laura Rosssi | laura.rossi@libero.it | laura.rossi@libero.it |
+------+------+---------------+-------------+--------------+-----------------------+-----------------------+



LIMIT 200;

SELECT 
    s.true_match_id,
    c.id,
    s.id,
    s.kind, 
    s.name AS signup_name,
    c.name AS customer_name, 
    s.email, 
    c.email,
    lev_distance(s.name, c.name) AS name_dist, 
    lev_distance(SUBSTRING_INDEX(s.email,'@',1), SUBSTRING_INDEX(c.email,'@',1)) AS email_dist
FROM signups s 
JOIN customers c 
    ON c.city = s.city 
    AND (
        (SUBSTRING_INDEX(c.name, ' ', -1) LIKE CONCAT(LEFT(SUBSTRING_INDEX(s.name, ' ', -1), 1), '%')) 
        and 
        (SUBSTRING_INDEX(c.name, ' ', 1) LIKE CONCAT(LEFT(SUBSTRING_INDEX(s.name, ' ', 1), 1), '%'))
    ) -- <== This closing parenthesis was missing
WHERE lev_distance(s.name, c.name) BETWEEN 1 AND 3
  AND lev_distance(SUBSTRING_INDEX(s.email, '@', 1), SUBSTRING_INDEX(c.email, '@', 1)) <= 2
ORDER BY 
    name_dist DESC, 
    email_dist DESC;



FROM signups s JOIN customers c ON c.city = s.city AND SUBSTRING_INDEX(c.name,' ',-1) LIKE CONCAT(LEFT(SUBSTRING_INDEX(s.name,' ',-1),1),'%')

-- Two assertions that keep the answer key honest (both must be 0):
SELECT (SELECT COUNT(*) FROM signups s JOIN customers c ON c.name = s.name
          WHERE s.true_match_id = 0)                       AS zero_rows_with_a_customer_name,
       (SELECT COUNT(*) FROM signups WHERE true_match_id > 0
          AND true_match_id NOT IN (SELECT id FROM customers)) AS dangling_match_ids;


-- =====================================================================
-- 3.  WHAT YOU GET WITHOUT THE FUNCTION
--     Join on the name. It is the only tool SQL gives you.
-- =====================================================================

SELECT COUNT(*) AS found_by_exact_match
FROM signups s JOIN customers c ON c.name = s.name AND c.id = s.true_match_id;
--  249 of 1,200.  You just matched 20.8% of your duplicates and
--  declared the other 951 to be new customers. Nothing errored.

-- LIKE does not rescue it either - a typo in the middle of the string
-- defeats any prefix pattern, and a leading wildcard cannot use an index.
SELECT s.name AS signup, c.name AS customer
FROM signups s JOIN customers c ON c.name LIKE CONCAT(LEFT(s.name, 4), '%')
WHERE s.true_match_id > 0 AND c.id = s.true_match_id
LIMIT 5;


-- =====================================================================
-- 4.  BLOCKING - the bit that makes it affordable
--
--     3,000 x 2,000 = 6,000,000 comparisons is silly. Use SQL for what
--     SQL is good at: throw away pairs that cannot possibly match, then
--     run the expensive function only on the survivors.
--
--     Block on city + first letter of surname -> 22,285 pairs. 269x less.
-- =====================================================================

SELECT COUNT(*) AS candidate_pairs
FROM signups s
JOIN customers c
  ON c.city = s.city
 AND SUBSTRING_INDEX(c.name,' ',-1) LIKE CONCAT(LEFT(SUBSTRING_INDEX(s.name,' ',-1),1),'%');
-- ~22,285 pairs instead of 6,000,000


-- =====================================================================
-- 5.  THE MATCH
--     SQL narrows. JavaScript decides. One statement.
-- =====================================================================

SELECT s.id            AS signup_id,
       s.name          AS signup_name,
       c.id            AS customer_id,
       c.name          AS customer_name,
       s.city,
       lev_distance(s.name, c.name) AS dist,
       lev_ratio(s.name, c.name)    AS pct
FROM signups s
JOIN customers c
  ON c.city = s.city
 AND SUBSTRING_INDEX(c.name,' ',-1) LIKE CONCAT(LEFT(SUBSTRING_INDEX(s.name,' ',-1),1),'%')
WHERE lev_distance(s.name, c.name) BETWEEN 1 AND 3
ORDER BY dist, desc pct
LIMIT 30;


-- =====================================================================
-- 6.  HOW GOOD IS IT?   (this is the slide)
--     true_match_id lets us measure instead of guess.
-- =====================================================================

SELECT th.t                                                   AS max_distance,
       SUM(m.hit)                                             AS true_matches,
       ROUND(100 * SUM(m.hit) / 1200, 1)                      AS recall_pct,
       SUM(1 - m.hit)                                         AS false_pairs,
       ROUND(100 * SUM(m.hit) / COUNT(*), 1)                  AS precision_pct
FROM (SELECT 1 AS t UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) th
JOIN (
  SELECT s.id, s.true_match_id, c.id AS cid,
         lev_distance(s.name, c.name) AS d,
         (c.id = s.true_match_id) AS hit
  FROM signups s
  JOIN customers c
    ON c.city = s.city
   AND SUBSTRING_INDEX(c.name,' ',-1) LIKE CONCAT(LEFT(SUBSTRING_INDEX(s.name,' ',-1),1),'%')
) m ON m.d <= th.t
GROUP BY th.t
ORDER BY th.t;

--  Measured on this dataset:
--
--    max_distance  true_matches  recall_pct  false_pairs  precision_pct
--       1               620         51.7         102          85.9
--       2               878         73.2         261          77.1
--       3               973         81.1         358          73.1
--       4               984         82.0         625          61.2
--
--  Compare with 249 (20.8%) from the exact-name join.
--

-- 6b. WHERE DO THE FALSE POSITIVES COME FROM?
--     Not where you would guess. The `kind` column tells us.
SELECT s.kind, COUNT(*) AS false_pairs
FROM signups s
JOIN customers c
  ON c.city = s.city
 AND SUBSTRING_INDEX(c.name,' ',-1) LIKE CONCAT(LEFT(SUBSTRING_INDEX(s.name,' ',-1),1),'%')
WHERE s.true_match_id <> c.id
  AND lev_distance(s.name, c.name) <= 2
GROUP BY s.kind ORDER BY false_pairs DESC;

--  Measured, at distance <= 2 (261 false pairs) and <= 4 (625):
--
--            <= 2            <= 4
--    trap   248  (95%)       344  (55%)   <- doing exactly its job
--    dup      7  (3%)        154  (25%)
--    new      6  (2%)        127  (20%)
--
--  Three different failures:
--
--    trap  two different people really do have near-identical names.
--          Elena vs Eleni Laurent. Conti vs Conte. Novak vs Nowak.
--          No amount of string cleverness separates these.
--    new   a genuinely new person coincidentally resembles a customer
--    dup   a REAL duplicate matched the WRONG customer - within the
--          threshold of its true match AND of somebody else
--
--  Two of the three have fixes. See 6c and 6d.


-- 6c. KEEP ONLY THE BEST CANDIDATE PER SIGNUP
--     A signup is one person, so it can have at most one match. Rank the
--     candidates and take the closest. This removes most of the `dup`
--     false pairs without losing a single true match.
SELECT signup_id, signup_name, customer_id, customer_name, dist
FROM (
  SELECT s.id AS signup_id, s.name AS signup_name,
         c.id AS customer_id, c.name AS customer_name,
         lev_distance(s.name, c.name) AS dist,
         ROW_NUMBER() OVER (PARTITION BY s.id
                            ORDER BY lev_distance(s.name, c.name), c.id) AS rn
  FROM signups s
  JOIN customers c
    ON c.city = s.city
   AND SUBSTRING_INDEX(c.name,' ',-1) LIKE CONCAT(LEFT(SUBSTRING_INDEX(s.name,' ',-1),1),'%')
  WHERE lev_distance(s.name, c.name) <= 2
) r
WHERE rn = 1
ORDER BY dist, signup_id
LIMIT 20;

--  Measured effect - recall untouched, precision improves, but it only
--  cures the `dup` kind of error. It cannot help with the traps, because
--  for a trap the wrong customer IS the closest one.


-- =====================================================================
-- 6d. THE ACTUAL FIX: A SECOND SIGNAL
--
--     Elena Laurent and Eleni Laurent are one edit apart and always will
--     be. No threshold separates them, because the difference is not in
--     the spelling - it is that they are different people. So stop asking
--     the name to do all the work and bring in the email.
--
--     Two cheap calls to the same function, on two different columns.
-- =====================================================================

SELECT s.id, s.name AS signup_name, c.name AS customer_name,
       lev_distance(s.name, c.name)                                   AS name_dist,
       lev_distance(SUBSTRING_INDEX(s.email,'@',1),
                    SUBSTRING_INDEX(c.email,'@',1))                   AS email_dist
FROM signups s
JOIN customers c
  ON c.city = s.city
 AND SUBSTRING_INDEX(c.name,' ',-1) LIKE CONCAT(LEFT(SUBSTRING_INDEX(s.name,' ',-1),1),'%')
WHERE lev_distance(s.name, c.name) <= 4
  AND lev_distance(SUBSTRING_INDEX(s.email,'@',1),
                   SUBSTRING_INDEX(c.email,'@',1)) <= 2
ORDER BY name_dist DESC, s.id
LIMIT 20;

--  Measured. Recall is IDENTICAL on every row - the email condition only
--  ever removes wrong pairs:
--
--            name distance only          name AND email <= 2
--    th    true   recall   false  prec |  true   recall  false   prec
--    <=1    620    51.7%    102  85.9% |   620    51.7%      4  99.4%
--    <=2    878    73.2%    261  77.1% |   878    73.2%     11  98.8%
--    <=3    973    81.1%    358  73.1% |   973    81.1%     20  98.0%
--    <=4    984    82.0%    625  61.2% |   984    82.0%     24  97.6%
--
--  And notice what that buys: you can now open the name threshold all the
--  way to 4 - the most generous setting, the best recall - and precision
--  goes UP, not down. 82.0% recall at 97.6% precision.
--
--  Against 20.8% recall from the exact-name join we started with.
--
--  THE LESSON: one signal buys you recall. Two signals buy you precision.
--  And both of them are the same 20-line JavaScript function, called on a
--  different column.


-- =====================================================================
-- 7.  THE SAME TRICK INSIDE ONE TABLE
--     "Do we have this customer twice already?"
-- =====================================================================

SELECT a.id, a.name, b.id AS dup_id, b.name AS dup_name, a.city,
       lev_distance(a.name, b.name) AS dist
FROM customers a
JOIN customers b
  ON b.id > a.id                      -- each pair once
 AND b.city = a.city
 AND SUBSTRING_INDEX(b.name,' ',-1) LIKE CONCAT(LEFT(SUBSTRING_INDEX(a.name,' ',-1),1),'%')
WHERE lev_distance(a.name, b.name) BETWEEN 1 AND 2
ORDER BY dist, a.id
LIMIT 20;


-- =====================================================================
-- 8.  WHAT LEFT THE SERVER
-- =====================================================================

SET @b0 = (SELECT VARIABLE_VALUE FROM performance_schema.session_status
            WHERE VARIABLE_NAME = 'Bytes_sent');

SELECT COUNT(*) AS probable_duplicates
FROM signups s
JOIN customers c
  ON c.city = s.city
 AND SUBSTRING_INDEX(c.name,' ',-1) LIKE CONCAT(LEFT(SUBSTRING_INDEX(s.name,' ',-1),1),'%')
WHERE lev_distance(s.name, c.name) BETWEEN 1 AND 2;

SELECT (SELECT VARIABLE_VALUE FROM performance_schema.session_status
         WHERE VARIABLE_NAME = 'Bytes_sent') - @b0 AS bytes_left_the_server;

-- One number. The alternative - matching in an application - means
-- exporting 5,000 names, emails and cities to somewhere else first.
-- Names and email addresses are personal data. Now they are in an app
-- server's memory, in its logs, and inside your GDPR scope.


-- =====================================================================
--  Notes worth having ready:
--
--   * PL cannot do this. Levenshtein needs a 2-D matrix; the procedural
--     SQL language has no array type. Not slower - impossible.
--
--   * SOUNDEX() exists in MySQL and is not a substitute: it is
--     English-phonetic, ignores everything after the first four
--     consonant sounds, and rates "Müller" and "Miller" identical while
--     missing most real typos.
--
--   * The function uses two rolling rows rather than the full matrix,
--     so memory is O(shorter string) rather than O(n*m). For 80-char
--     names either is fine; for 500-char addresses it matters.
--
--   * Declare DETERMINISTIC NO SQL or CREATE FUNCTION fails with
--     ERROR 1418 when binary logging is on.
--
--   * Always block first. Without the join conditions this query is
--     6,000,000 function calls, and no index can help a predicate that
--     compares every row to every other row.
-- =====================================================================
