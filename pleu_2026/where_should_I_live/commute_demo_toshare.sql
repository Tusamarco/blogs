-- =====================================================================
--  "WHERE SHOULD I LIVE?"                     ROMA - metropolitan area
--
--  A four-stage demo. Read it in order; each stage produces a table the
--  next one consumes.
--
--    STAGE 0   the data. What is in the tables, what a week looks like,
--              and which person we follow through the whole demo.
--    STAGE 1   SQL. Raw stops -> weighted endpoints. This is set work,
--              and it is what SQL is unbeatable at.
--    STAGE 2   the calculation, THREE WAYS:
--                A. plain SQL   - exact, for GRID distance
--                B. JavaScript  - exact, for STRAIGHT-LINE distance
--                C. procedural SQL (PL) - same as B, 21x slower
--    STAGE 3   SQL. Turn coordinates into answers a human can act on,
--              for our person and for anybody, under any of the three.
--
--  WHAT THE DEMO IS ACTUALLY ABOUT: not "SQL is bad at maths". SQL solves
--  the grid-distance version of this problem EXACTLY, in one statement,
--  with no iteration (stage 2A). Change one thing - grid distance to
--  straight-line distance - and no single statement can express it any
--  more. That one square root is the whole talk.
--
--  MEASURED FIGURES in the comments were verified against the source
--  CSVs or measured on MySQL 9.7.2. See AUDIT.txt for the provenance of
--  every number, and validate_model.sql for the checks you should run on
--  your own server before presenting any of it.
--
--  Requires MySQL Enterprise Edition with the MLE component for stage 2B:
--      INSTALL COMPONENT 'file://component_mle';   -- in a SEPARATE session
--  Stages 0, 1, 2A, 2C and 3 run on Community and on Percona Server.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS whereto;
USE whereto;

-- Drop in dependency order, so the script is re-runnable.
DROP VIEW      IF EXISTS v_itinerary;
DROP PROCEDURE IF EXISTS best_home_js;
DROP PROCEDURE IF EXISTS best_home_pl;
DROP PROCEDURE IF EXISTS best_home_pl_all;
DROP PROCEDURE IF EXISTS bench;
DROP FUNCTION  IF EXISTS km_between;
DROP FUNCTION  IF EXISTS mins_for;
DROP TABLE     IF EXISTS homes;
DROP TABLE     IF EXISTS endpoint_weights;
DROP TABLE     IF EXISTS commute_key;
DROP TABLE     IF EXISTS stops;
DROP TABLE     IF EXISTS places;


-- #####################################################################
-- ##  STAGE 0  -  THE DATA                                           ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 0.1  TABLES
-- ---------------------------------------------------------------------

CREATE TABLE places (
  place_id INT PRIMARY KEY,
  name     VARCHAR(40)  NOT NULL,
  lat      DECIMAL(9,4) NOT NULL,
  lon      DECIMAL(9,4) NOT NULL,
  in_wedge TINYINT      NOT NULL   -- 1 = Flaminia-Nomentana sector
) ENGINE=InnoDB;

-- THE TRIP LOG. One row per STOP, not per journey. This grain is the
-- whole reason the demo works:
--   tour_id  groups the stops of ONE trip out of the house
--   seq      orders them within that trip
-- Without those two columns you cannot tell a direct trip from a chained
-- one, and every number downstream depends on that distinction.
CREATE TABLE stops (
  person_id INT         NOT NULL,
  tour_id   INT         NOT NULL,
  seq       INT         NOT NULL,
  place_id  INT         NOT NULL,
  day       CHAR(3)     NOT NULL,     -- decoration; nothing reads it
  hour      TINYINT     NOT NULL,     -- decoration; nothing reads it
  purpose   VARCHAR(20) NOT NULL,
  PRIMARY KEY (tour_id, seq),
  KEY ix_person (person_id)
) ENGINE=InnoDB;

-- Independently computed reference answers, used only to check our work.
CREATE TABLE commute_key (
  person_id    INT PRIMARY KEY,
  scenario     VARCHAR(12)   NOT NULL,
  best_x       DECIMAL(18,9) NOT NULL,
  best_y       DECIMAL(18,9) NOT NULL,
  best_min     DECIMAL(14,6) NOT NULL,
  centroid_min DECIMAL(14,6) NOT NULL,
  ref_steps    INT NOT NULL,
  n_tours      INT NOT NULL,
  n_endpoints  INT NOT NULL,
  n_midonly    INT NOT NULL
) ENGINE=InnoDB;

CREATE TABLE people (
  person_id INT PRIMARY KEY,
  name      VARCHAR(20) NOT NULL,
  lastname  VARCHAR(20) NOT NULL,
  email     VARCHAR(60) NOT NULL,
  gender    ENUM('F','M') NOT NULL,
  age       TINYINT UNSIGNED NOT NULL,
  UNIQUE KEY uq_email (email)
) ENGINE=InnoDB;


-- ---------------------------------------------------------------------
-- 0.2  LOAD   (CSVs produced by commute_data.py)
-- ---------------------------------------------------------------------


LOAD DATA INFILE '/media/psf/Home/work/mysql/Conferences/2026/pleu/javascript_2026/where_should_I_live/places.csv'
  INTO TABLE places FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n'
  (place_id, name, lat, lon, in_wedge);

LOAD DATA INFILE '/media/psf/Home/work/mysql/Conferences/2026/pleu/javascript_2026/where_should_I_live/stops.csv'
  INTO TABLE stops FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n'
  (person_id, tour_id, seq, place_id, day, hour, purpose);

LOAD DATA INFILE '/media/psf/Home/work/mysql/Conferences/2026/pleu/javascript_2026/where_should_I_live/commute_key.csv'
  INTO TABLE commute_key FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n'
  (person_id, scenario, best_x, best_y, best_min, centroid_min,
   ref_steps, n_tours, n_endpoints, n_midonly);

LOAD DATA INFILE '/media/psf/Home/work/mysql/Conferences/2026/pleu/javascript_2026/where_should_I_live/people.csv'
  INTO TABLE people FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n'
  (person_id, name, lastname, email, gender, age);


-- ---------------------------------------------------------------------
-- 0.3  TWO HELPER FUNCTIONS.  Plain SQL, no JavaScript.
--
--   Rome sits at 41.90 N. At that parallel one degree of longitude is
--   111.320 * cos(41.90) = 82.85 km, against 111.132 km for a degree of
--   latitude. Everything in this script uses that flat projection, so
--   distances are in kilometres and the two axes are comparable.
-- ---------------------------------------------------------------------

CREATE FUNCTION km_between(lat1 DOUBLE, lon1 DOUBLE, lat2 DOUBLE, lon2 DOUBLE)
RETURNS DOUBLE DETERMINISTIC NO SQL
RETURN SQRT(POW((lon2 - lon1) * 111.320 * COS(RADIANS(41.90)), 2)
          + POW((lat2 - lat1) * 111.132, 2));

CREATE FUNCTION mins_for(km DOUBLE)
RETURNS DOUBLE DETERMINISTIC NO SQL
RETURN km * 1.30 / 16.0 * 60.0;   -- 1.3 detour factor, 16 km/h in Rome


-- ---------------------------------------------------------------------
-- 0.4  WHAT LOADED
-- ---------------------------------------------------------------------

SELECT (SELECT COUNT(*) FROM places)                    AS places,
       (SELECT COUNT(*) FROM places WHERE in_wedge = 1) AS in_wedge,
       (SELECT COUNT(DISTINCT person_id) FROM stops)    AS people,
       (SELECT COUNT(DISTINCT tour_id)  FROM stops)     AS tours,
       (SELECT COUNT(*) FROM stops)                     AS stops;
-- EXPECT: 60, 30, 2000, 23333, 44347.

-- How long is a tour? THIS is what makes the problem non-trivial.
SELECT stops_in_tour, COUNT(*) AS tours,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM (SELECT tour_id, MAX(seq) AS stops_in_tour FROM stops GROUP BY tour_id) t
GROUP BY stops_in_tour ORDER BY stops_in_tour;
--   1 stop  10,862  46.6%
--   2 stops  3,928  16.8%
--   3 stops  8,543  36.6%
--  So 53.4% of tours are CHAINED, mean 1.90 stops. People do not go
--  home -> office -> home -> gym -> home. They chain errands together,
--  and that changes which places can influence where they should live.


-- ---------------------------------------------------------------------
-- 0.5  TOP ITINERARIES BY DISTANCE
--
--   CAREFUL: at this point there is no home in the data - only the
--   places people go. So the only distance we can measure yet is
--   BETWEEN STOPS. That is not a limitation, it is a preview: the
--   inter-stop legs are exactly the part of the week that NO address can
--   change. Stage 3 gives the full home-to-home version.
-- ---------------------------------------------------------------------

WITH s AS (
  SELECT st.person_id, st.tour_id, st.seq, p.name, p.lat, p.lon,
         MAX(st.seq) OVER (PARTITION BY st.tour_id) AS n_stops
  FROM stops st JOIN places p ON p.place_id = st.place_id
),
km AS (                      -- distance: needs CONSECUTIVE PAIRS
  SELECT a.person_id, a.tour_id,
         SUM(km_between(a.lat, a.lon, b.lat, b.lon)) AS inter_stop_km
  FROM s a
  JOIN s b ON b.tour_id = a.tour_id AND b.seq = a.seq + 1
  GROUP BY a.person_id, a.tour_id
),
route AS (                   -- route: needs ALL STOPS
  SELECT tour_id, MAX(n_stops) AS stops,
         GROUP_CONCAT(name ORDER BY seq SEPARATOR ' -> ') AS legs
  FROM s
  GROUP BY tour_id
)
SELECT k.person_id, k.tour_id, r.stops,
       ROUND(k.inter_stop_km, 2)           AS inter_stop_km,
       ROUND(mins_for(k.inter_stop_km), 1) AS minutes,
       r.legs
FROM km k
JOIN route r USING (tour_id)
ORDER BY inter_stop_km DESC, k.tour_id
LIMIT 10;

--  MEASURED. 12,471 tours have inter-stop legs at all. The longest:
--    19.61 km  person 1305  tour 15240  Boccea -> EUR -> Nomentano
--    19.59 km  person 1810  tour 21146  Salario -> Boccea -> EUR
--    19.24 km  person 1760  tour 20522  Ciampino -> Centocelle -> Porta di Roma
--    19.08 km  person 1540  tour 17977  Settebagni -> Sant Agnese -> Ottavia
--  median 5.68 km, mean 6.18 km.
--
--  Every kilometre in that column is unfixable. Moving house does not
--  shorten the leg from Boccea to EUR.


-- ---------------------------------------------------------------------
-- 0.6  ONE PERSON'S WEEK, IN FULL
--
--   Change @pid and re-run. This is the query to open the demo with -
--   it makes the data concrete before any maths appears.
-- ---------------------------------------------------------------------

SET @pid = 1761;

SELECT s.tour_id,
       s.day,
       MAX(s.seq)                                AS stops,
       IF(MAX(s.seq) = 1, 'DIRECT', 'chained')   AS kind,
       CONCAT('HOME -> ',
              GROUP_CONCAT(p.name ORDER BY s.seq SEPARATOR ' -> '),
              ' -> HOME')                        AS itinerary
FROM stops s
JOIN places p ON p.place_id = s.place_id
WHERE s.person_id = @pid
GROUP BY s.tour_id, s.day
ORDER BY FIELD(s.day,'Mon','Tue','Wed','Thu','Fri','Sat','Sun'), s.tour_id;


SELECT CONCAT(pe.name, ' ', pe.lastname) AS person,
       pe.age,
       s.day,       
       CONCAT('HOME -> ',GROUP_CONCAT(p.name ORDER BY s.seq SEPARATOR ' -> '),' -> HOME') AS itinerary
FROM stops s
JOIN places p ON p.place_id = s.place_id
JOIN people pe ON pe.person_id = s.person_id
WHERE s.person_id = @pid
GROUP BY pe.name, pe.lastname, s.day,pe.age,s.tour_id
ORDER BY FIELD(s.day,'Mon','Tue','Wed','Thu','Fri','Sat','Sun');



SELECT s.day,       
       GROUP_CONCAT(p.name ORDER BY s.seq SEPARATOR ' -> ') AS itinerary
FROM stops s
JOIN places p ON p.place_id = s.place_id
JOIN people pe ON pe.person_id = s.person_id
WHERE s.person_id = @pid
GROUP BY pe.name, pe.lastname, s.day,pe.age,s.tour_id
ORDER BY FIELD(s.day,'Mon','Tue','Wed','Thu','Fri','Sat','Sun');



-- Federico week with km (after we have calculate the weight and the Home)
SET @pid = 1761;
SET @method = 'js';


WITH s AS (
  SELECT st.tour_id, st.seq, st.day, p.name, p.lat, p.lon,
         MAX(st.seq) OVER (PARTITION BY st.tour_id) AS n_stops
  FROM stops st JOIN places p ON p.place_id = st.place_id
  WHERE st.person_id = @pid
),
h AS (
  SELECT hlat, hlon FROM homes
  WHERE person_id = @pid AND method = @method
),
legs AS (
  SELECT s.tour_id, s.day, km_between(h.hlat, h.hlon, s.lat, s.lon) AS km
  FROM s CROSS JOIN h WHERE s.seq = 1
  UNION ALL
  SELECT a.tour_id, a.day, km_between(a.lat, a.lon, b.lat, b.lon)
  FROM s a JOIN s b ON b.tour_id = a.tour_id AND b.seq = a.seq + 1
  UNION ALL
  SELECT s.tour_id, s.day, km_between(s.lat, s.lon, h.hlat, h.hlon)
  FROM s CROSS JOIN h WHERE s.seq = s.n_stops
),
per_tour AS (
  SELECT k.tour_id, k.day, k.km, r.itin
  FROM (SELECT tour_id, day, SUM(km) AS km FROM legs GROUP BY tour_id, day) k
  JOIN (SELECT tour_id,
               CONCAT('HOME -> ',
                      GROUP_CONCAT(name ORDER BY seq SEPARATOR ' -> '),
                      ' -> HOME') AS itin
        FROM s GROUP BY tour_id) r USING (tour_id)
)
SELECT day,ROUND(sum(km), 2) AS km, ROUND(sum(mins_for(km)), 2) AS minutes, REPLACE(GROUP_CONCAT(itin SEPARATOR ' -> '),'HOME -> HOME -> ','') as itin
FROM per_tour group by day
ORDER BY FIELD(day,'Mon','Tue','Wed','Thu','Fri','Sat','Sun');


WITH s AS (
  SELECT st.tour_id, st.seq, st.day, p.name, p.lat, p.lon,
         MAX(st.seq) OVER (PARTITION BY st.tour_id) AS n_stops
  FROM stops st JOIN places p ON p.place_id = st.place_id
  WHERE st.person_id = @pid
),
h AS (
  SELECT hlat, hlon FROM homes
  WHERE person_id = @pid AND method = @method
),
legs AS (
  SELECT s.tour_id, s.day, km_between(h.hlat, h.hlon, s.lat, s.lon) AS km
  FROM s CROSS JOIN h WHERE s.seq = 1
  UNION ALL
  SELECT a.tour_id, a.day, km_between(a.lat, a.lon, b.lat, b.lon)
  FROM s a JOIN s b ON b.tour_id = a.tour_id AND b.seq = a.seq + 1
  UNION ALL
  SELECT s.tour_id, s.day, km_between(s.lat, s.lon, h.hlat, h.hlon)
  FROM s CROSS JOIN h WHERE s.seq = s.n_stops
),
per_tour AS (
  SELECT k.tour_id, k.day, k.km, r.itin
  FROM (SELECT tour_id, day, SUM(km) AS km FROM legs GROUP BY tour_id, day) k
  JOIN (SELECT tour_id,
               CONCAT('HOME -> ',
                      GROUP_CONCAT(name ORDER BY seq SEPARATOR ' -> '),
                      ' -> HOME') AS itin
        FROM s GROUP BY tour_id) r USING (tour_id)
)SELECT ROUND(sum(km), 2) AS km, ROUND(sum(mins_for(km)), 2)/60 AS minutes from per_tour;



--  person 1761, sixteen tours (every one starts and ends at home, which
--  we do not know yet):
--    20529  chained  Marconi -> Flaminio
--    20530  chained  Grottarossa -> Tomba di Nerone -> Corso Francia
--    20531  chained  Porta di Roma -> Casal Boccone -> Talenti
--    20532  DIRECT   Ponte di Nona
--    20533  chained  Corso Francia -> Villaggio Olimpico
--    20534  chained  Casal Boccone -> Talenti
--    20535  chained  Marconi -> Flaminio -> Villaggio Olimpico
--    20536  DIRECT   Castel Giubileo
--    20537  chained  Marconi -> Flaminio -> Corso Francia
--    20538  chained  Grottarossa -> Tomba di Nerone -> Castel Giubileo
--    20539  DIRECT   Ponte di Nona
--    20540  chained  Flaminio -> Tomba di Nerone -> Grottarossa
--    20541  DIRECT   Marconi
--    20542  chained  Porta di Roma -> Castel Giubileo
--    20543  DIRECT   Porta di Roma
--    20544  DIRECT   Ponte di Nona
--
--  READ TOURS 20530, 20538 AND 20540. All three pass through TOMBA DI
--  NERONE and not one of them starts or ends there. Hold that thought
--  until stage 1.


-- ---------------------------------------------------------------------
-- 0.7  WHY PERSON 1761 IS THE DEMO CASE
--
--  
-- ---------------------------------------------------------------------

SELECT k.person_id, k.scenario,
       k.n_tours, k.n_endpoints, k.n_midonly,
       (SELECT COUNT(*) FROM (SELECT tour_id FROM stops
          WHERE person_id = k.person_id GROUP BY tour_id
          HAVING MAX(seq) > 1) c)                         AS chained_tours
FROM commute_key k WHERE k.person_id = @pid;

--  1. scenario = 'normal'. The generator plants five special shapes
--     (dominant / onapoint / collinear / twoclusters / single). This
--     person is none of them - nothing about them was constructed.
--
--  2. 10 of 16 tours are chained = 62%, ABOVE the population's 53.4%.
--     The example is not a soft case.
--
--  3. Tomba di Nerone is a middle stop in THREE separate tours, so
--     stage 1 has something visible to remove.
--
--  4. All three methods in stage 2 give DIFFERENT answers for them:
--     Parioli (SQL grid), Sacco Pastore (SQL centroid), and
--     Batteria Nomentana (JavaScript). That is what makes the
--     comparison in stage 3 worth showing.
--
--  5. Their week contains no airport runs, so it reads as ordinary
--     errands rather than as an outlier.
--
--  AND THE HONEST CAVEAT: for person 1761 the JavaScript is worth 18.0
--  minutes a week over the best plain SQL can manage. That is 16 hours a
--  year - real, but not spectacular. Bigger cases exist (up to 46 h/yr).
--  This one was chosen because it can carry the WHOLE demo, not because
--  it maximises the headline.


-- #####################################################################
-- ##  STAGE 1  -  FROM STOPS TO WEIGHTED ENDPOINTS                   ##
-- #####################################################################

-- ---------------------------------------------------------------------
-- 1.1  HOW THE WEIGHT WORKS  -  the modelling step, in words first
--
--   A tour is  home -> A -> B -> C -> home.  Its total cost is
--
--       d(home,A) + d(A,B) + d(B,C) + d(C,home)
--
--   Move the house and only the FIRST and LAST terms change. The middle
--   ones do not contain `home` at all - they are constants.
--
--   So for the purpose of choosing an address:
--
--     * a DIRECT tour  home -> A -> home  contributes  2 x d(home,A).
--       A is both the first and the last stop, so it counts TWICE.
--     * a CHAINED tour contributes d(home, first) + d(last, home).
--       The first stop counts once, the last counts once, and every
--       middle stop counts ZERO.
--
--   The weight of a place, for a person, is therefore simply:
--
--       how many times it is the FIRST or LAST stop of a tour
--
--   and a place that is only ever in the middle has weight zero - it
--   drops out of the decision entirely, however often they go there.
--
--   Total travel then splits cleanly in two:
--
--       total(home) = SUM over places [ w * d(home, place) ]     <- movable
--                   + SUM of all inter-stop legs                 <- FIXED
--
--   Stage 2 minimises the first term. Nothing can touch the second.
-- ---------------------------------------------------------------------

CREATE TABLE endpoint_weights (
  person_id INT NOT NULL,
  place_id  INT NOT NULL,
  w         INT NOT NULL,       -- times this place starts or ends a tour
  PRIMARY KEY (person_id, place_id)
) ENGINE=InnoDB;


-- ---------------------------------------------------------------------
-- 1.2  THE QUERY, AND STORE IT
--
--   FIRST_VALUE and LAST_VALUE over a partition ordered by seq. One
--   statement, exact, no iteration. This is the part of the problem SQL
--   should own, and you should not rewrite it in JavaScript out of
--   enthusiasm.
-- ---------------------------------------------------------------------

INSERT INTO endpoint_weights (person_id, place_id, w)
WITH ends AS (
  SELECT person_id, tour_id,
         FIRST_VALUE(place_id) OVER (PARTITION BY tour_id ORDER BY seq
             ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS first_place,
         LAST_VALUE(place_id)  OVER (PARTITION BY tour_id ORDER BY seq
             ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_place
  FROM stops
),
one_per_tour AS (
  SELECT DISTINCT person_id, tour_id, first_place, last_place FROM ends
),
endpoints AS (
  SELECT person_id, first_place AS place_id FROM one_per_tour  -- leaving home
  UNION ALL
  SELECT person_id, last_place  AS place_id FROM one_per_tour  -- coming back
)
SELECT person_id, place_id, COUNT(*) FROM endpoints
GROUP BY person_id, place_id;

-- ---------------------------------------------------------------------
-- 1.3  VERIFY IT  -  a free correctness check
-- ---------------------------------------------------------------------

SELECT (SELECT COUNT(*) FROM endpoint_weights)            AS weight_rows,
       (SELECT SUM(w)   FROM endpoint_weights)            AS total_weight,
       (SELECT 2 * COUNT(DISTINCT tour_id) FROM stops)    AS twice_tours;
-- EXPECT: 16232, 46666, 46666.
-- Every tour contributes exactly two endpoints, so total_weight must
-- equal twice the tour count. If it does not, stop and find out why
-- before trusting anything downstream.

-- How much did we just throw away, and was it safe to?
SELECT COUNT(*)                  AS midonly_place_person_pairs,
       COUNT(DISTINCT person_id) AS people_affected
FROM (SELECT DISTINCT person_id, place_id FROM stops) v
LEFT JOIN endpoint_weights e USING (person_id, place_id)
WHERE e.place_id IS NULL;
-- EXPECT: 1620 pairs across 1188 people.
-- More than half the population has at least one place they visit every
-- single week that has NO bearing on where they should live.


-- ---------------------------------------------------------------------
-- 1.4  OUR PERSON'S WEIGHTS
-- ---------------------------------------------------------------------

select concat(p.name,' ',p.lastname) as person,pl.name, e.w as weight from endpoint_weights e join people p on p.person_id = e.person_id join places pl on pl.place_id=e.place_id  where p.person_id=@pid limit 10;
+----------------+--------------------+--------+
| person         | name               | weight |
+----------------+--------------------+--------+
| Federico Gatti | Flaminio           |      2 |
| Federico Gatti | Villaggio Olimpico |      2 |
| Federico Gatti | Corso Francia      |      3 |
| Federico Gatti | Grottarossa        |      3 |
| Federico Gatti | Castel Giubileo    |      4 |
| Federico Gatti | Talenti            |      2 |
| Federico Gatti | Porta di Roma      |      4 |
| Federico Gatti | Casal Boccone      |      1 |
| Federico Gatti | Marconi            |      5 |
| Federico Gatti | Ponte di Nona      |      6 |
+----------------+--------------------+--------+


SELECT p.name, e.w,
       (SELECT COUNT(*) FROM stops s
         WHERE s.person_id = @pid AND s.place_id = p.place_id) AS visits
FROM endpoint_weights e JOIN places p ON p.place_id = e.place_id
WHERE e.person_id = @pid
ORDER BY e.w DESC, p.name;

--  person 1761 - ten rows, total weight 32 = 2 x 16 tours:
--    Ponte di Nona       6    three DIRECT tours, x2 each
--    Marconi             5    one direct tour (x2) plus three chained starts
--    Castel Giubileo     4
--    Porta di Roma       4
--    Corso Francia       3
--    Grottarossa         3
--    Flaminio            2
--    Talenti             2
--    Villaggio Olimpico  2
--    Casal Boccone       1
--
--  NOW THE POINT. They visit ELEVEN places. Only TEN are in this list.

SELECT p.name, COUNT(*) AS visits_per_week
FROM stops s JOIN places p ON p.place_id = s.place_id
LEFT JOIN endpoint_weights e
       ON e.person_id = s.person_id AND e.place_id = s.place_id
WHERE s.person_id = @pid AND e.place_id IS NULL
GROUP BY p.name;

--  TOMBA DI NERONE, visited 3 times a week, weight 0. They drive through
--  it in tours 20530, 20538 and 20540 and never once travel between home
--  and it, so no address can change those legs. It is gone from the
--  decision - and you cannot tell that by looking at a place, only at a
--  place-on-a-tour. Which is why deriving the weights is a SQL job.


-- #####################################################################
-- ##  STAGE 2  -  THE CALCULATION, THREE WAYS                        ##
-- #####################################################################
--
--  All three methods answer "which point minimises SUM(w * distance)?"
--  and all three write into ONE table, so stage 3 can treat them
--  interchangeably.
--
--  They differ in what "distance" means, and that is the whole lesson:
--
--    A. SQL grid   |dx| + |dy|            EXACT, one statement, no loop
--    B. JavaScript sqrt(dx^2 + dy^2)      EXACT, needs a loop
--    C. PL         sqrt(dx^2 + dy^2)      same answer as B, 21x slower
-- #####################################################################

CREATE TABLE homes (
  method     VARCHAR(12)   NOT NULL,   -- 'grid' | 'centroid' | 'js' | 'pl'
  person_id  INT           NOT NULL,
  hlat       DECIMAL(12,7) NOT NULL,
  hlon       DECIMAL(12,7) NOT NULL,
  minutes_wk DECIMAL(14,6) NULL,       -- movable travel, straight-line
  steps      INT           NULL,       -- iterations, where applicable
  PRIMARY KEY (method, person_id)
) ENGINE=InnoDB;


-- ---------------------------------------------------------------------
-- 2.1  METHOD A  -  PLAIN SQL, EXACT, FOR GRID DISTANCE
--
--   If travel is measured in city blocks - |dx| + |dy| - the problem
--   SEPARATES. Total cost becomes
--
--       SUM(w * |x - xi|)  +  SUM(w * |y - yi|)
--
--   two independent one-dimensional problems. And the minimiser of a
--   weighted sum of absolute deviations is the WEIGHTED MEDIAN. So:
--
--       best x = weighted median of the x coordinates
--       best y = weighted median of the y coordinates
--
--   computed separately, exactly, with a window function. No iteration,
--   no approximation, no procedure. SQL wins this outright - say so.
-- ---------------------------------------------------------------------

INSERT INTO homes (method, person_id, hlat, hlon)
WITH pts AS (
  SELECT e.person_id, e.w,
         p.lon * 111.320 * COS(RADIANS(41.90)) AS x,
         p.lat * 111.132                       AS y
  FROM endpoint_weights e JOIN places p ON p.place_id = e.place_id
),
-- running weight along each axis, plus the total, per person
cx AS (
  SELECT person_id, x,
         SUM(w) OVER (PARTITION BY person_id ORDER BY x) AS run,
         SUM(w) OVER (PARTITION BY person_id)            AS tot
  FROM pts
),
cy AS (
  SELECT person_id, y,
         SUM(w) OVER (PARTITION BY person_id ORDER BY y) AS run,
         SUM(w) OVER (PARTITION BY person_id)            AS tot
  FROM pts
),
-- the weighted median is the first coordinate at which the running
-- weight reaches half the total
mx AS (SELECT person_id, MIN(x) AS gx FROM cx WHERE run * 2 >= tot GROUP BY person_id),
my AS (SELECT person_id, MIN(y) AS gy FROM cy WHERE run * 2 >= tot GROUP BY person_id)
SELECT 'grid', mx.person_id,
       my.gy / 111.132,
       mx.gx / (111.320 * COS(RADIANS(41.90)))
FROM mx JOIN my USING (person_id);

-- While we are here: the centroid, which is what AVG() gives and what
-- most people reach for first. Stored so stage 3 can compare it too.
INSERT INTO homes (method, person_id, hlat, hlon)
SELECT 'centroid', e.person_id,
       SUM(p.lat * e.w) / SUM(e.w),
       SUM(p.lon * e.w) / SUM(e.w)
FROM endpoint_weights e JOIN places p ON p.place_id = e.place_id
GROUP BY e.person_id;

-- Score both of them on STRAIGHT-LINE distance, so every method in the
-- homes table is measured the same way.
UPDATE homes h
SET minutes_wk = (
  SELECT SUM(e.w * mins_for(km_between(h.hlat, h.hlon, p.lat, p.lon)))
  FROM endpoint_weights e JOIN places p ON p.place_id = e.place_id
  WHERE e.person_id = h.person_id)
WHERE h.method IN ('grid', 'centroid');

SELECT method, COUNT(*) AS people, ROUND(AVG(minutes_wk), 1) AS avg_min_wk
FROM homes GROUP BY method;
-- EXPECT: grid 2000, centroid 2000.


-- 2.1b  OUR PERSON, under method A
SELECT h.method,
       ROUND(h.hlat, 5) AS lat, ROUND(h.hlon, 5) AS lon,
       (SELECT p.name FROM places p
          ORDER BY km_between(h.hlat, h.hlon, p.lat, p.lon) LIMIT 1) AS nearest_district,
       ROUND(h.minutes_wk, 1) AS straight_line_min_wk,

       ROUND((SELECT SUM(e.w * mins_for(
                  ABS(h.hlon - p.lon) * 111.320 * COS(RADIANS(41.90))
                + ABS(h.hlat - p.lat) * 111.132))
              FROM endpoint_weights e JOIN places p ON p.place_id = e.place_id
              WHERE e.person_id = h.person_id), 1) AS grid_min_wk
FROM homes h
WHERE h.person_id = @pid AND h.method IN ('grid', 'centroid')
ORDER BY h.method;




-- ---------------------------------------------------------------------
-- 2.2  NOW CHANGE THE METRIC, AND WATCH SQL STOP
--
--   Replace |dx| + |dy| with sqrt(dx^2 + dy^2) and the axes COUPLE: the
--   best x depends on the best y and vice versa. There is no median
--   trick left, nothing to rearrange, no window function that helps.
--   The only way is to iterate - guess a point, compute a weighted
--   average of directions, move, repeat (Weiszfeld's algorithm).
--
--   And the one construct SQL has for iterating cannot do it.
-- ---------------------------------------------------------------------

-- THE FOUR-LINE PROOF. No tables, works on Community too. Run it live.
WITH RECURSIVE t AS (
  SELECT 1 AS n
  UNION ALL
  SELECT SUM(n) + 1 FROM t WHERE n < 5       -- <-- one aggregate
)
SELECT * FROM t;
-- EXPECT: ERROR 3575 (HY000) - a recursive CTE may contain neither
-- aggregate nor window functions in its recursive block. Every Weiszfeld
-- step needs a SUM. Dead end. ONE aggregate is enough to trigger it.

-- The same thing on our real tables, so nobody can say it was a toy.
-- Everything here resolves; the ONLY illegal part is the aggregate in the
-- recursive member. Note the anchor's SUM and GROUP BY are perfectly
-- legal - the ban applies only after UNION ALL.
WITH RECURSIVE
located AS (
  SELECT e.person_id,
         p.lon * 111.320 * COS(RADIANS(41.90)) AS x,
         p.lat * 111.132                       AS y, e.w
  FROM endpoint_weights e JOIN places p ON p.place_id = e.place_id
),
step AS (
  SELECT person_id, SUM(x*w)/SUM(w) AS x, SUM(y*w)/SUM(w) AS y, 0 AS k
  FROM located GROUP BY person_id                    -- legal here
  UNION ALL
  SELECT s.person_id,
         SUM(l.w * l.x / SQRT(POW(s.x-l.x,2) + POW(s.y-l.y,2)))
           / SUM(l.w   / SQRT(POW(s.x-l.x,2) + POW(s.y-l.y,2))),
         SUM(l.w * l.y / SQRT(POW(s.x-l.x,2) + POW(s.y-l.y,2)))
           / SUM(l.w   / SQRT(POW(s.x-l.x,2) + POW(s.y-l.y,2))),
         s.k + 1
  FROM step s JOIN located l ON l.person_id = s.person_id
  WHERE s.k < 200
  GROUP BY s.person_id, s.x, s.y, s.k                -- NOT legal here
)
SELECT * FROM step WHERE k = 200 LIMIT 10;
-- EXPECT: ERROR 3575 again.


-- ---------------------------------------------------------------------
-- 2.3  METHOD B  -  JAVASCRIPT, EXACT, FOR STRAIGHT-LINE DISTANCE
--
--   Weiszfeld's algorithm. Start at the centroid; repeatedly replace the
--   current guess with a weighted average of the places, each weighted
--   INVERSELY by its distance from the guess; stop when it settles.
--
---------------------------------------------

CREATE PROCEDURE best_home_js()
LANGUAGE JAVASCRIPT AS $$
  const LAT0 = 41.90                        // Roma
  const KLAT = 111.132
  const KLON = 111.320 * Math.cos(LAT0 * Math.PI / 180)
  const DETOUR = 1.30                       // roads are not straight
  const SPEED  = 16.0                       // km/h door to door
  const MINS = km => km * DETOUR / SPEED * 60.0

  // ---- ONE scan of the weights that STAGE 1 prepared ---------------
  const who = new Map()
  let res = session.runSql(
    "SELECT e.person_id, p.lat, p.lon, e.w " +
    "FROM endpoint_weights e JOIN places p ON p.place_id = e.place_id " +
    "ORDER BY e.person_id")
  let row = res.fetchOne()
  while (row) {
    const [pid, lat, lon, w] = row.toArray()
    const id = Number(pid)
    if (!who.has(id)) who.set(id, [])
    who.get(id).push([Number(lon) * KLON, Number(lat) * KLAT, Number(w)])
    row = res.fetchOne()
  }

  const cost = (x, y, ds) => {
    let m = 0
    for (const [px, py, w] of ds) m += w * MINS(Math.hypot(x - px, y - py))
    return m
  }

  const solve = (ds) => {
    if (ds.length === 1) return [ds[0][0], ds[0][1], 1, 'single place']

    let W = 0
    for (const [, , w] of ds) W += w
    let x = 0, y = 0                        // start at the centroid,
    for (const [px, py, w] of ds) {         // which is what AVG() gives
      x += px * w / W; y += py * w / W
    }

    for (let k = 1; k <= 20000; k++) {
      let nx = 0, ny = 0, den = 0, onPoint = null
      for (const [px, py, w] of ds) {
        const d = Math.hypot(x - px, y - py)
        // dividing by the distance means landing exactly on a place is
        // 0/0. Measured: from a centroid start this never fires across
        // all 2,000 people. A guard, not a hot path.
        if (d < 1e-12) { onPoint = [px, py]; continue }
        nx += w * px / d
        ny += w * py / d
        den += w / d
      }
      if (den === 0) return [onPoint[0], onPoint[1], k, 'on a place']
      nx /= den; ny /= den
      if (onPoint !== null &&
          cost(onPoint[0], onPoint[1], ds) <= cost(nx, ny, ds))
        return [onPoint[0], onPoint[1], k, 'on a place']
      if (Math.hypot(nx - x, ny - y) < 1e-10) return [nx, ny, k, 'converged']
      x = nx; y = ny
    }
    return [x, y, 20000, 'hit step cap']
  }

  // ---- write the answers back into a SQL table ---------------------
  // session.runSql() takes NO bound parameters in this MLE build
  // (ERROR 6113), so statements are assembled as text and quoting is the
  // developer s problem. Hence q().
  //
  const q = s => "'" + String(s).replace(/\\/g, "\\\\").replace(/'/g, "''") + "'"
  //"
  session.runSql("DELETE FROM homes WHERE method = 'js'")

  const vals = []
  for (const [pid, ds] of who) {
    const [x, y, k, how] = solve(ds)
    vals.push("('js'," + pid + "," + (y / KLAT).toFixed(7) + "," +
              (x / KLON).toFixed(7) + "," + cost(x, y, ds).toFixed(6) + "," + k + ")")
    if (vals.length === 500) {
      session.runSql("INSERT INTO homes (method,person_id,hlat,hlon,minutes_wk,steps) VALUES " + vals.join(","))
      vals.length = 0
    }
  }
  if (vals.length)
    session.runSql("INSERT INTO homes (method,person_id,hlat,hlon,minutes_wk,steps) VALUES " + vals.join(","))
$$;

-- 2.3a  RUN IT FOR EVERYBODY.  One CALL, all 2,000 people.
CALL best_home_js();

SELECT COUNT(*) AS people,
       MIN(steps) AS min_steps, MAX(steps) AS max_steps,
       SUM(steps >= 20000) AS hit_the_cap
FROM homes WHERE method = 'js';
-- MEASURED on 9.7.2: 2000 people, min 1, max 20000, 2 at the cap.
-- Broken down by outcome: 1,993 converged (8 to 15,802 steps), 5 single
-- place, 2 hit the cap. Steps median 67, 90th percentile 217.
--
-- Weiszfeld is only LINEARLY convergent, so it creeps, and the count
-- depends entirely on the person's geometry rather than on the size of
-- the problem. That is what kills "just unroll a fixed number of
-- iterations as nested derived tables" - there is no fixed number.

-- Check it against the independent reference.
SELECT COUNT(*)                                          AS people,
       ROUND(MAX(h.minutes_wk - k.best_min), 9)          AS worst_excess_min_wk
FROM homes h JOIN commute_key k USING (person_id)
WHERE h.method = 'js';
-- EXPECT: worst excess about 0.000015 min/wk - one millisecond a week,
-- and only on the two people who hit the step cap.

-- 2.3b  OUR PERSON, under method B
SELECT h.method, ROUND(h.hlat,5) AS lat, ROUND(h.hlon,5) AS lon,
       (SELECT p.name FROM places p
          ORDER BY km_between(h.hlat, h.hlon, p.lat, p.lon) LIMIT 1) AS nearest_district,
       ROUND(h.minutes_wk,1) AS straight_line_min_wk, h.steps
FROM homes h WHERE h.method = 'js' AND h.person_id = @pid;
-- person 1761: 41.94073, 12.50716 -> Batteria Nomentana, 979.0, 63 steps.
-- Against the grid answer's 993.3 and the centroid's 997.0.


-- ---------------------------------------------------------------------
-- 2.4  METHOD C  -  PROCEDURAL SQL. SAME ANSWER. THIS IS THE HONEST BIT.
--
-- ---------------------------------------------------------------------

DELIMITER //

CREATE PROCEDURE best_home_pl(IN p_pid INT, OUT o_x DOUBLE,
                              OUT o_y DOUBLE, OUT o_steps INT)
BEGIN
  DECLARE v_x, v_y, v_nx, v_ny DOUBLE;
  DECLARE k INT DEFAULT 0;

  -- seed at the centroid: exactly the answer AVG() gives
  SELECT SUM(p.lon * 111.320 * COS(RADIANS(41.90)) * e.w) / SUM(e.w),
         SUM(p.lat * 111.132 * e.w) / SUM(e.w)
    INTO v_x, v_y
  FROM endpoint_weights e JOIN places p ON p.place_id = e.place_id
  WHERE e.person_id = p_pid;

  REPEAT
    SET k = k + 1;

    -- ONE Weiszfeld step. This SELECT contains the very aggregate that
    -- ERROR 3575 refuses inside a recursive CTE. Here it is just legal.
    SELECT SUM(e.w * x / d) / SUM(e.w / d),
           SUM(e.w * y / d) / SUM(e.w / d)
      INTO v_nx, v_ny
    FROM (
      SELECT e2.w,
             p.lon * 111.320 * COS(RADIANS(41.90)) AS x,
             p.lat * 111.132                       AS y,
             GREATEST(SQRT(
               POW(v_x - p.lon * 111.320 * COS(RADIANS(41.90)), 2) +
               POW(v_y - p.lat * 111.132, 2)), 1e-12) AS d
      FROM endpoint_weights e2 JOIN places p ON p.place_id = e2.place_id
      WHERE e2.person_id = p_pid
    ) e;

    SET o_steps = k;
    IF SQRT(POW(v_nx - v_x, 2) + POW(v_ny - v_y, 2)) < 1e-10 THEN
      SET v_x = v_nx; SET v_y = v_ny; SET k = -1;   -- signal convergence
    ELSE
      SET v_x = v_nx; SET v_y = v_ny;
    END IF;
  UNTIL k = -1 OR k >= 20000 END REPEAT;

  SET o_x = v_x; SET o_y = v_y;
END //

-- 2.4a  a driver, so PL does the same job as the JavaScript: whole
--       population, into the same table.
CREATE PROCEDURE best_home_pl_all(IN p_max_steps INT)
BEGIN
  DECLARE done INT DEFAULT 0;
  DECLARE v_pid INT;
  DECLARE vx, vy DOUBLE; DECLARE vk INT;
  -- pass 19999 to skip the two pathological people, 999999 for all
  DECLARE cur CURSOR FOR
    SELECT person_id FROM commute_key WHERE ref_steps <= p_max_steps;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;
  DELETE FROM homes WHERE method = 'pl';
  OPEN cur;
  read_loop: LOOP
    FETCH cur INTO v_pid;
    IF done = 1 THEN LEAVE read_loop; END IF;
    CALL best_home_pl(v_pid, vx, vy, vk);
    INSERT INTO homes (method, person_id, hlat, hlon, steps)
    VALUES ('pl', v_pid, vy / 111.132,
            vx / (111.320 * COS(RADIANS(41.90))), vk);
  END LOOP;
  CLOSE cur;
END //

-- a timing wrapper. 
CREATE PROCEDURE bench(IN which VARCHAR(10), IN max_steps INT)
BEGIN
  DECLARE t0 DATETIME(6);
  SET t0 = SYSDATE(6);
  IF which = 'js' THEN CALL best_home_js();
                  ELSE CALL best_home_pl_all(max_steps); END IF;
  SELECT which AS run, max_steps AS step_limit,
         TIMESTAMPDIFF(MICROSECOND, t0, SYSDATE(6)) / 1000000 AS seconds;
END //

DELIMITER ;

-- 2.4b  RUN IT FOR EVERYBODY, and time it. Run each twice, quote the second.
CALL bench('pl', 19999);      -- 1,998 people: the two cap cases excluded
CALL bench('pl', 999999);     -- all 2,000
CALL bench('js', 0);

| run  | step_limit | seconds |
+------+------------+---------+
| pl   |      19999 |  8.3787 |
+------+------------+---------+

(root@localhost) [whereto]>CALL bench('pl', 999999);     -- all 2,000
| run  | step_limit | seconds |
+------+------------+---------+
| pl   |     999999 | 10.9507 |
+------+------------+---------+

| run  | step_limit | seconds |
+------+------------+---------+
| js   |          0 |  1.2030 |
+------+------------+---------+


-- score the PL answers the same way as the others
UPDATE homes h
SET minutes_wk = (
  SELECT SUM(e.w * mins_for(km_between(h.hlat, h.hlon, p.lat, p.lon)))
  FROM endpoint_weights e JOIN places p ON p.place_id = e.place_id
  WHERE e.person_id = h.person_id)
WHERE h.method = 'pl';

-- 2.4c  OUR PERSON, under method C
CALL best_home_pl(@pid, @x, @y, @k);
SELECT ROUND(@y / 111.132, 5)                          AS lat,
       ROUND(@x / (111.320 * COS(RADIANS(41.90))), 5)  AS lon,
       @k                                              AS iterations;
-- person 1761: 41.94073, 12.50716 in 63 iterations. The same answer as
-- the JavaScript, as it must be - it is the same algorithm.


-- ---------------------------------------------------------------------
-- 2.5  THE THREE METHODS SIDE BY SIDE
-- ---------------------------------------------------------------------


SELECT 
h.method,ROUND(h.hlat, 5) AS lat, 
ROUND(h.hlon, 5) AS lon,
(SELECT p.name FROM places p ORDER BY km_between(h.hlat, h.hlon, p.lat, p.lon) LIMIT 1) AS nearest_district,        ROUND(h.minutes_wk, 1) AS straight_line_min_wk,
ROUND((SELECT SUM(e.w * mins_for(ABS(h.hlon - p.lon) * 111.320 * COS(RADIANS(41.90)) + ABS(h.hlat - p.lat) * 111.132)) 
FROM endpoint_weights e JOIN places p ON p.place_id = e.place_id
WHERE e.person_id = h.person_id), 1) AS grid_min_wk FROM homes h WHERE h.person_id = @pid
 ORDER BY h.method;
+----------+----------+----------+--------------------+----------------------+-------------+
| method   | lat      | lon      | nearest_district   | straight_line_min_wk | grid_min_wk |
+----------+----------+----------+--------------------+----------------------+-------------+
| centroid | 41.93209 | 12.51788 | Sacco Pastore      |                997.0 |        1278 |
| grid     | 41.93300 | 12.48900 | Parioli            |                993.3 |        1207 |
| js       | 41.94073 | 12.50716 | Batteria Nomentana |                979.0 |      1267.8 |
+----------+----------+----------+--------------------+----------------------+-------------+



-- do B and C agree?
SELECT COUNT(*)                                                  AS people,
       ROUND(MAX(km_between(a.hlat, a.hlon, b.hlat, b.hlon)) * 1000000, 3)
                                                                 AS worst_gap_mm,
       SUM(a.steps <> b.steps)                                   AS step_differences
FROM homes a JOIN homes b USING (person_id)
WHERE a.method = 'js' AND b.method = 'pl';
-- MEASURED: 2,000 people, worst separation 0.000001 m - ONE MICROMETRE.
-- 60 step counts differ, because MySQL's DOUBLE arithmetic and V8's
-- accumulate the sums in a different order and cross the 1e-10 tolerance
-- a moment apart. The ANSWERS do not care.

SELECT method, COUNT(*) AS people,
       ROUND(AVG(minutes_wk), 1) AS avg_straight_min_wk,
       ROUND(MIN(minutes_wk), 1) AS best, ROUND(MAX(minutes_wk), 1) AS worst
FROM homes GROUP BY method ORDER BY avg_straight_min_wk;

--  WHAT IT COSTS, measured on 9.7.2:
--
--    method        statements   seconds   distance metric it optimises
--    ------------  ----------   -------   ----------------------------
--    grid (2A)              1      <0.1   |dx| + |dy|      EXACT
--    js   (2B)              6      0.52   sqrt(dx^2+dy^2)  EXACT
--    pl   (2C)        327,033     11.00   sqrt(dx^2+dy^2)  EXACT
--


-- #####################################################################
-- ##  STAGE 3  -  THE ANSWERS                                        ##
-- #####################################################################
--
--  Stage 2 produced coordinates. Only a join makes them useful, and that
--  join is ordinary SQL over the table the procedure wrote. This is the
--  stage neither half reaches alone.
--
--  Because all three methods live in `homes` keyed by (method,
--  person_id), every query below works for ANY method and ANY person.
--  Set the two variables and re-run.
-- #####################################################################

SET @pid    = 1761;
SET @method = 'js';       -- 'js' | 'pl' | 'grid' | 'centroid'


-- ---------------------------------------------------------------------
-- 3.1  WHERE SHOULD THIS PERSON LIVE?
--
--   One person, one method, one row. Naming the nearest district is what
--   makes it actionable: a pair of coordinates is not an answer anybody
--   can act on or argue with.
-- ---------------------------------------------------------------------
SELECT h.person_id,concat(pl.name,' ',pl.lastname) as who, h.method,
       ROUND(h.hlat, 5) AS lat, ROUND(h.hlon, 5) AS lon,
       n.name           AS nearest_district,
       ROUND(km_between(h.hlat, h.hlon, n.lat, n.lon), 2) AS km_from_its_centre,

       ELT(FLOOR((DEGREES(ATAN2(
              (h.hlon - n.lon) * 111.320 * COS(RADIANS(41.90)),
              (h.hlat - n.lat) * 111.132)) + 382.5) / 45) % 8 + 1,
           'N','NE','E','SE','S','SW','W','NW')            AS bearing,
       ROUND(h.minutes_wk, 1)      AS movable_min_wk,
       ROUND(h.minutes_wk / 60, 1) AS movable_hours_wk,
       h.steps
FROM homes h join people pl on pl.person_id = h.person_id 
JOIN LATERAL (SELECT p.place_id, p.name, p.lat, p.lon FROM places p
              ORDER BY km_between(h.hlat, h.hlon, p.lat, p.lon)
              LIMIT 1) n ON TRUE
WHERE h.person_id = @pid;


--  person 1761, all four methods:
--    method    lat        lon        district            offset      movable
--    js        41.94073   12.50716   Batteria Nomentana  0.58 km NW    979.0
--    pl        41.94073   12.50716   Batteria Nomentana  0.58 km NW    979.0
--    grid      41.93300   12.48900   Parioli             0.56 km N     993.3
--    centroid  41.93209   12.51787   Sacco Pastore       0.12 km SE    997.0
--
--  FOUR METHODS, THREE DIFFERENT DISTRICTS. And note that Batteria
--  Nomentana is NOT one of the eleven places this person visits - so no
--  query over their own rows could ever have proposed it. Across the
--  population that is true for 868 of 2,000 people (43%).


-- ---------------------------------------------------------------------
-- 3.3  THE SAME, FOR ANY PERSON
--
--   Nothing above is specific to 1761. Change @pid and @method and every
--   query in stage 3 works. These two do the whole population at once.
-- ---------------------------------------------------------------------

-- 3.3a  who should move where, ranked by what it saves them against the
--       naive answer. Works for any method.
SELECT h.person_id, k.scenario,
       n.name                                          AS move_near,
       ROUND(h.minutes_wk, 1)                          AS new_min_wk,
       ROUND(c.minutes_wk - h.minutes_wk, 1)           AS saves_min_wk,
       ROUND((c.minutes_wk - h.minutes_wk) * 52 / 60, 0) AS saves_hours_yr
FROM homes h
JOIN homes c ON c.person_id = h.person_id AND c.method = 'centroid'
JOIN commute_key k ON k.person_id = h.person_id
JOIN LATERAL (SELECT p.name FROM places p
              ORDER BY km_between(h.hlat, h.hlon, p.lat, p.lon)
              LIMIT 1) n ON TRUE
WHERE h.method = @method
ORDER BY saves_min_wk DESC
LIMIT 20;

-- 3.3b  how do the methods compare, over everybody?
SELECT COUNT(*)                                                 AS people,
       ROUND(AVG(g.minutes_wk - j.minutes_wk), 2)               AS grid_costs_more_avg,
       ROUND(MAX(g.minutes_wk - j.minutes_wk), 1)               AS grid_costs_more_worst,
       SUM(g.minutes_wk - j.minutes_wk <= 0.01)                 AS grid_already_optimal,
       SUM(ABS(g.hlat - j.hlat) < 0.0001
       AND ABS(g.hlon - j.hlon) < 0.0001)                       AS same_point
FROM homes g JOIN homes j USING (person_id)
WHERE g.method = 'grid' AND j.method = 'js';
