CREATE TABLE IF NOT EXISTS shipments (
    id BIGINT PRIMARY KEY,
    product_name TEXT NOT NULL,
    quantity INT NOT NULL,
    destination TEXT NOT NULL,
    region TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL
);

CREATE PUBLICATION shipments_pub FOR TABLE shipments;
