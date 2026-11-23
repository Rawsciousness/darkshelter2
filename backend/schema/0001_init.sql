-- DARKSHELTER bookings database (Cloudflare D1, database "darkshelter-bookings")
-- Empty structure only: no workshops, dates, prices or cameras yet.
-- Money is stored in cents (e.g. 6500 = €65.00). Dates/times are ISO 8601 text in UTC.

PRAGMA foreign_keys = ON;

-- Workshop types (e.g. darkroom printing, film developing)
CREATE TABLE IF NOT EXISTS workshops (
  id              INTEGER PRIMARY KEY,
  slug            TEXT    NOT NULL UNIQUE,
  title_en        TEXT    NOT NULL,
  title_el        TEXT    NOT NULL,
  description_en  TEXT,
  description_el  TEXT,
  duration_min    INTEGER NOT NULL CHECK (duration_min > 0),
  price_cents     INTEGER NOT NULL CHECK (price_cents >= 0),
  currency        TEXT    NOT NULL DEFAULT 'EUR',
  location        TEXT    NOT NULL DEFAULT 'Moutoullas',
  active          INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1)),
  created_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- Dated sessions of a workshop, each with its own seat limit
CREATE TABLE IF NOT EXISTS workshop_sessions (
  id           INTEGER PRIMARY KEY,
  workshop_id  INTEGER NOT NULL REFERENCES workshops(id),
  starts_at    TEXT    NOT NULL,
  capacity     INTEGER NOT NULL CHECK (capacity > 0),
  price_cents  INTEGER CHECK (price_cents IS NULL OR price_cents >= 0), -- optional override of the workshop price
  status       TEXT    NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled','cancelled')),
  note         TEXT,
  created_at   TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  UNIQUE (workshop_id, starts_at)
);

-- Cameras available to rent
CREATE TABLE IF NOT EXISTS cameras (
  id                 INTEGER PRIMARY KEY,
  slug               TEXT    NOT NULL UNIQUE,
  name               TEXT    NOT NULL,
  format             TEXT,                         -- e.g. 35mm, 120
  daily_price_cents  INTEGER NOT NULL CHECK (daily_price_cents >= 0),
  deposit_cents      INTEGER NOT NULL DEFAULT 0 CHECK (deposit_cents >= 0),
  currency           TEXT    NOT NULL DEFAULT 'EUR',
  pickup_location    TEXT    NOT NULL DEFAULT 'Kalopanayiotis',
  active             INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1)),
  created_at         TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- Days a camera is unavailable for reasons other than bookings (repair, personal use)
CREATE TABLE IF NOT EXISTS camera_blocks (
  id          INTEGER PRIMARY KEY,
  camera_id   INTEGER NOT NULL REFERENCES cameras(id),
  start_date  TEXT    NOT NULL,   -- YYYY-MM-DD, inclusive
  end_date    TEXT    NOT NULL,   -- YYYY-MM-DD, inclusive
  reason      TEXT,
  CHECK (end_date >= start_date)
);

-- One row per booking: a workshop seat booking or a camera rental
CREATE TABLE IF NOT EXISTS bookings (
  id                     TEXT    PRIMARY KEY,      -- random id, also the customer's reference
  kind                   TEXT    NOT NULL CHECK (kind IN ('workshop','rental')),
  status                 TEXT    NOT NULL DEFAULT 'held'
                           CHECK (status IN ('held','paid','cancelled','expired','refunded')),
  -- workshop bookings
  session_id             INTEGER REFERENCES workshop_sessions(id),
  seats                  INTEGER CHECK (seats IS NULL OR seats > 0),
  -- camera rentals
  camera_id              INTEGER REFERENCES cameras(id),
  rental_start           TEXT,                     -- YYYY-MM-DD, inclusive
  rental_end             TEXT,                     -- YYYY-MM-DD, inclusive
  -- customer
  customer_name          TEXT    NOT NULL,
  email                  TEXT    NOT NULL,
  phone                  TEXT,
  lang                   TEXT    NOT NULL DEFAULT 'en' CHECK (lang IN ('en','el')),
  notes                  TEXT,
  -- money and payment
  amount_cents           INTEGER NOT NULL CHECK (amount_cents >= 0),
  currency               TEXT    NOT NULL DEFAULT 'EUR',
  hold_expires_at        TEXT,                     -- unpaid holds are released after this time
  stripe_checkout_id     TEXT    UNIQUE,
  stripe_payment_intent  TEXT,
  created_at             TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  paid_at                TEXT,
  cancelled_at           TEXT,
  CHECK (
    (kind = 'workshop' AND session_id IS NOT NULL AND seats IS NOT NULL
       AND camera_id IS NULL AND rental_start IS NULL AND rental_end IS NULL)
    OR
    (kind = 'rental' AND camera_id IS NOT NULL AND rental_start IS NOT NULL AND rental_end IS NOT NULL
       AND rental_end >= rental_start AND session_id IS NULL AND seats IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS bookings_session_idx ON bookings (session_id, status);
CREATE INDEX IF NOT EXISTS bookings_camera_idx  ON bookings (camera_id, status, rental_start, rental_end);
CREATE INDEX IF NOT EXISTS bookings_hold_idx    ON bookings (status, hold_expires_at);
CREATE INDEX IF NOT EXISTS bookings_email_idx   ON bookings (email);
CREATE INDEX IF NOT EXISTS sessions_start_idx   ON workshop_sessions (starts_at);
CREATE INDEX IF NOT EXISTS camera_blocks_idx    ON camera_blocks (camera_id, start_date, end_date);

-- Stripe notifications already processed, so a repeated notification is never applied twice
CREATE TABLE IF NOT EXISTS payment_events (
  stripe_event_id  TEXT PRIMARY KEY,
  type             TEXT NOT NULL,
  booking_id       TEXT REFERENCES bookings(id),
  received_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- Seats left per session: paid seats plus unexpired holds count as taken
CREATE VIEW IF NOT EXISTS session_availability AS
SELECT s.id AS session_id,
       s.workshop_id,
       s.starts_at,
       s.capacity,
       s.capacity - COALESCE((
         SELECT SUM(b.seats) FROM bookings b
          WHERE b.session_id = s.id
            AND (b.status = 'paid'
                 OR (b.status = 'held' AND b.hold_expires_at > strftime('%Y-%m-%dT%H:%M:%SZ','now')))
       ), 0) AS seats_left,
       s.status
  FROM workshop_sessions s;
