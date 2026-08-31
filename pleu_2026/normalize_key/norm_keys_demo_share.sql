-- =====================================================================
--  norm_keys() - why one small JavaScript function earns its place
--
--  The situation every integration team knows: four partners send you
--  the same document, and every one of them capitalises the keys
--  differently. JSON paths in SQL are case sensitive, so every query
--  you write is a guessing game.
--
--  Requires MySQL Enterprise Edition with the MLE component:
--      INSTALL COMPONENT 'file://component_mle';   -- in a SEPARATE session
-- =====================================================================

CREATE DATABASE IF NOT EXISTS jsondemo;
USE jsondemo;

DROP FUNCTION IF EXISTS norm_keys;
DROP TABLE    IF EXISTS events;


-- ---------------------------------------------------------------------
-- The function. Recursively lower-cases every key, at every depth,
-- through objects and arrays, without knowing the shape in advance.
-- ---------------------------------------------------------------------

CREATE FUNCTION norm_keys(d JSON)
RETURNS JSON
DETERMINISTIC NO SQL
LANGUAGE JS AS $$
  const walk = (j) => {
    if (j === null || typeof j !== 'object') return j     // null first!
    if (Array.isArray(j)) return j.map(walk)
    const out = {}
    for (const [k, v] of Object.entries(j)) out[k.toLowerCase()] = walk(v)
    return out
  }
  return walk(typeof d === 'string' ? JSON.parse(d) : d)
$$;


-- ---------------------------------------------------------------------
-- Four partners. Same order document. Same meaning. Four spellings.
-- ---------------------------------------------------------------------

CREATE TABLE events (
  id     INT AUTO_INCREMENT PRIMARY KEY,
  source VARCHAR(20) NOT NULL,
  doc    JSON        NOT NULL
) ENGINE=InnoDB;

INSERT INTO events (source, doc) VALUES
('acme',    '{"orderId":1001,"Customer":{"Id":7,"Country":"IT","Tier":"gold"},
              "Items":[{"SKU":"A-1","Qty":2,"UnitPrice":10.50},
                       {"SKU":"B-2","Qty":1,"UnitPrice":30.00}]}'),
('acme',    '{"orderId":1002,"Customer":{"Id":9,"Country":"DE","Tier":"silver"},
              "Items":[{"SKU":"A-1","Qty":5,"UnitPrice":10.50}]}'),
('globex',  '{"OrderID":2001,"customer":{"ID":7,"country":"IT","tier":"gold"},
              "items":[{"sku":"C-3","qty":3,"unitprice":12.00}]}'),
('globex',  '{"OrderID":2002,"customer":{"ID":11,"country":"FR","tier":"bronze"},
              "items":[{"sku":"B-2","qty":4,"unitprice":30.00}]}'),
('initech', '{"ORDERID":3001,"CUSTOMER":{"ID":9,"COUNTRY":"DE","TIER":"silver"},
              "ITEMS":[{"SKU":"A-1","QTY":1,"UNITPRICE":10.50},
                       {"SKU":"C-3","QTY":2,"UNITPRICE":12.00}]}'),
('umbrella','{"orderid":4001,"customer":{"id":7,"country":"IT","tier":"gold"},
              "items":[{"sku":"D-4","qty":10,"unitprice":2.25}]}'),
('umbrella','{"orderid":4002,"customer":{"id":11,"country":"FR","tier":"bronze"},
              "items":[{"sku":"A-1","qty":2,"unitprice":10.50}]}');


-- =====================================================================
-- 1.  THE PROBLEM, IN ONE QUERY
--     Four spellings of the same three keys.
-- =====================================================================

SELECT source, JSON_KEYS(doc) AS top_level_keys FROM events ORDER BY id;

--  acme      ["Items", "orderId", "Customer"]
--  globex    ["items", "OrderID", "customer"]
--  initech   ["ITEMS", "ORDERID", "CUSTOMER"]
--  umbrella  ["items", "orderid", "customer"]


-- =====================================================================
-- 2.  THE SILENT WRONG ANSWER
--     Write the obvious query against the casing you happened to see
--     first. It runs. It returns rows. It is wrong.
-- =====================================================================

SELECT COUNT(*) AS rows_found, SUM(doc->>'$.customer.id' IS NOT NULL) AS matched
FROM events;
--  7 rows in the table, 3 matched. No error, no warning. Four orders
--  quietly missing from the report.


-- =====================================================================
-- 3.  WHAT IT COSTS TO BE CORRECT WITHOUT THE FUNCTION
--
--     One JSON_TABLE can pull the scalars AND the line items in a single
--     pass, using NESTED PATH. Lovely - except every path is a literal,
--     so you need the whole thing once per partner, UNION ALL-ed.
--     Four branches. Same query, written four times.
-- =====================================================================

SELECT country, tier, customer_id,
       COUNT(DISTINCT order_id)       AS orders,
       SUM(qty)                       AS units,
       ROUND(SUM(qty * unitprice), 2) AS revenue
FROM (
  SELECT jt.* FROM events e,
    JSON_TABLE(e.doc, '$' COLUMNS (
      order_id    INT         PATH '$.orderId',
      customer_id INT         PATH '$.Customer.Id',
      country     VARCHAR(2)  PATH '$.Customer.Country',
      tier        VARCHAR(10) PATH '$.Customer.Tier',
      NESTED PATH '$.Items[*]' COLUMNS (
        sku VARCHAR(20) PATH '$.SKU', qty INT PATH '$.Qty',
        unitprice DECIMAL(10,2) PATH '$.UnitPrice'))) jt
  WHERE e.source = 'acme'
  UNION ALL
  SELECT jt.* FROM events e,
    JSON_TABLE(e.doc, '$' COLUMNS (
      order_id    INT         PATH '$.OrderID',
      customer_id INT         PATH '$.customer.ID',
      country     VARCHAR(2)  PATH '$.customer.country',
      tier        VARCHAR(10) PATH '$.customer.tier',
      NESTED PATH '$.items[*]' COLUMNS (
        sku VARCHAR(20) PATH '$.sku', qty INT PATH '$.qty',
        unitprice DECIMAL(10,2) PATH '$.unitprice'))) jt
  WHERE e.source = 'globex'
  UNION ALL
  SELECT jt.* FROM events e,
    JSON_TABLE(e.doc, '$' COLUMNS (
      order_id    INT         PATH '$.ORDERID',
      customer_id INT         PATH '$.CUSTOMER.ID',
      country     VARCHAR(2)  PATH '$.CUSTOMER.COUNTRY',
      tier        VARCHAR(10) PATH '$.CUSTOMER.TIER',
      NESTED PATH '$.ITEMS[*]' COLUMNS (
        sku VARCHAR(20) PATH '$.SKU', qty INT PATH '$.QTY',
        unitprice DECIMAL(10,2) PATH '$.UNITPRICE'))) jt
  WHERE e.source = 'initech'
  UNION ALL
  SELECT jt.* FROM events e,
    JSON_TABLE(e.doc, '$' COLUMNS (
      order_id    INT         PATH '$.orderid',
      customer_id INT         PATH '$.customer.id',
      country     VARCHAR(2)  PATH '$.customer.country',
      tier        VARCHAR(10) PATH '$.customer.tier',
      NESTED PATH '$.items[*]' COLUMNS (
        sku VARCHAR(20) PATH '$.sku', qty INT PATH '$.qty',
        unitprice DECIMAL(10,2) PATH '$.unitprice'))) jt
  WHERE e.source = 'umbrella'
) x
GROUP BY country, tier, customer_id
ORDER BY revenue DESC;

--  Every branch hard-wires a partner name AND that partner's spelling.
--  Partner number five means editing every report you own.


-- =====================================================================
-- 4.  THE SAME ANSWER, WITH THE FUNCTION
--
--     ONE statement. One JSON_TABLE. No partner names anywhere, and
--     norm_keys() is evaluated exactly once per row.
-- =====================================================================

SELECT jt.country,
       jt.tier,
       jt.customer_id,
       COUNT(DISTINCT jt.order_id)          AS orders,
       SUM(jt.qty)                          AS units,
       ROUND(SUM(jt.qty * jt.unitprice), 2) AS revenue
FROM events e,
     JSON_TABLE(norm_keys(e.doc), '$' COLUMNS (
       order_id    INT         PATH '$.orderid',
       customer_id INT         PATH '$.customer.id',
       country     VARCHAR(2)  PATH '$.customer.country',
       tier        VARCHAR(10) PATH '$.customer.tier',
       NESTED PATH '$.items[*]' COLUMNS (
         sku       VARCHAR(20)   PATH '$.sku',
         qty       INT           PATH '$.qty',
         unitprice DECIMAL(10,2) PATH '$.unitprice')
     )) AS jt
GROUP BY jt.country, jt.tier, jt.customer_id
ORDER BY revenue DESC;

--  60-odd lines became 18, and the day partner five arrives you change
--  nothing at all.


-- =====================================================================
-- 5.  AND NOW THE QUESTIONS YOU COULD NOT ASK BEFORE
--     Best-selling SKU across every partner. Against four spellings this
--     needed another four-way UNION. Now it is one statement.
-- =====================================================================

SELECT jt.sku,
       SUM(jt.qty)                          AS units,
       ROUND(SUM(jt.qty * jt.unitprice), 2) AS revenue,
       COUNT(DISTINCT jt.customer_id)       AS buyers,
       GROUP_CONCAT(DISTINCT jt.country ORDER BY jt.country) AS countries
FROM events e,
     JSON_TABLE(norm_keys(e.doc), '$' COLUMNS (
       customer_id INT        PATH '$.customer.id',
       country     VARCHAR(2) PATH '$.customer.country',
       NESTED PATH '$.items[*]' COLUMNS (
         sku       VARCHAR(20)   PATH '$.sku',
         qty       INT           PATH '$.qty',
         unitprice DECIMAL(10,2) PATH '$.unitprice')
     )) AS jt
GROUP BY jt.sku
ORDER BY revenue DESC;


-- =====================================================================
-- 6.  IN PRODUCTION: FIX IT AT THE DOOR
-- =====================================================================

-- Calling norm_keys() per row is fine for a report. If the documents are
-- large or the table is hot, normalise on the way in instead:
--
ALTER TABLE events ADD COLUMN doc_norm JSON;
UPDATE events SET doc_norm = norm_keys(doc);
CREATE TRIGGER events_norm_bi BEFORE INSERT ON events
     FOR EACH ROW SET NEW.doc_norm = norm_keys(NEW.doc);
--
-- A stored function cannot appear in a GENERATED ALWAYS AS expression,
-- so it has to be a real column plus a trigger. Then every query above
-- runs against doc_norm and the function never appears in a report.


