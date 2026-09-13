# R1B Existing Scraper Integration Matrix

R1 uses the existing retailer collectors as the execution plane. R1 does not replace them.

Current repository review supports 21 visible implementation slots: Adorama, Amazon, B&H Photo, BJ's, CDW, Costco, Crutchfield, Dell, Harbor Freight, Kohl's, Lenovo, Lowe's, Micro Center, Newegg, Office Depot, Sam's Club, Sears, Staples, Target, Best Buy, and Walmart. Slot 22 is deliberately unidentified rather than fabricated.

For each scraper R1B binds repository path, git commit, deterministic package-tree SHA, entrypoint/package hashes, test/build/execution commands, exact input contract, Bright Data method/dataset/unlocker, geographic capabilities, DB ingest targets, interface evidence, and certification status.

A parser table or migration is not enough to make a scraper executable. R1C compiles only into a certified existing-scraper contract; R1D dispatches the same hash-bound scraper asset.
