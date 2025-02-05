# inet-location-db

This Bash script downloads and processes public Regional Internet Registry (RIR) and Border Gateway Protocol (BGP) RouteViews data to create an offline database that maps Autonomous system (AS) numbers and IP prefixes to country codes. The script produces four output files:

- **asn2country.txt** – Mapping of each ASN to its country.
- **prefix2asn.txt** – Mapping of BGP-announced prefixes to their origin ASNs (from a RouteViews RIB dump).
- **prefix2country.txt** – Mapping of BGP prefixes to country codes
- **prefix2countrydelegated.txt** – Mapping of delegated IP prefixes to country codes, derived from the RIR delegated extended files

It uses the latest available RIR files for ARIN, APNIC, LACNIC, AFRINIC, and RIPE.

## Features

- **RIR Data Download and Parsing:**  
  Downloads the latest delegated extended files from ARIN, APNIC, LACNIC, AFRINIC, and RIPE and parses them to build the ASN-to-Country mapping.

- **BGP Data Processing:**  
  Downloads a RouteViews RIB dump, decompresses it, and runs `bgpdump` to generate a mapping from BGP prefixes to origin ASNs, and then joins this with the ASN data to derive a prefix-to-country mapping.

- **Delegated Prefix Mapping:**  
  Creates a separate mapping of delegated prefixes to country codes from the RIR files. Only allocations with a size that is a power of two are converted to a CIDR notation.

## Requirements

- **Bash** (compatible with GNU Bash)
- **curl**
- **bgpdump** (ensure it is installed and in your PATH)
- **awk** (GNU Awk is recommended; the script avoids bitwise operations by using arithmetic loops)
- **bunzip2** and **bzip2** (for decompressing and compressing files)
- A working Internet connection to download data from the RIR FTP servers and RouteViews.

## Usage

1. **Make the script executable:**

   ```bash
   chmod +x build_asn_country_db.sh
   ```

2. **Run the script:**

   ```bash
   ./build_asn_country_db.sh
   ```

   By default, the script uses the latest RIR data (and yesterday’s date for naming the RouteViews RIB dump). If you wish to override the date, set the `RIR_DATE` environment variable:

   ```bash
   export RIR_DATE=20250203
   ./build_asn_country_db.sh
   ```

## Output Files

After successful execution, you will find the following files (compressed as `.bz2`):

- **asn2country.txt.bz2**  
  A sorted and deduplicated list of ASN-to-country mappings (format: `ASN COUNTRY`).

- **prefix2asn.txt.bz2**  
  A mapping of IP prefixes (from the RouteViews RIB) to origin ASNs (format: `prefix ASN`).

- **prefix2country.txt.bz2**  
  A mapping of IP prefixes to country codes derived by joining the above two files (format: `prefix COUNTRY`).

- **prefix2countrydelegated.txt.bz2**  
  A mapping of delegated IP prefixes (only power-of-two allocations) to country codes (format: `prefix COUNTRY`).


## Contributing

Contributions, bug reports, and feature requests are welcome. Feel free to open an issue or submit a pull request.

## Acknowledgements

- The script leverages publicly available data from ARIN, APNIC, LACNIC, AFRINIC, and RIPE.
- Special thanks to the maintainers of RouteViews and bgpdump for providing valuable resources.
