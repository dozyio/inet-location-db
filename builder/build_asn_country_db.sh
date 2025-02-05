#!/usr/bin/env bash
#
# 1) Determine date: 
#    - If $RIR_DATE is set, use it.
#    - Otherwise, figure out yesterday's date in a cross-platform way (macOS vs Linux).
# 2) Download & parse RIR delegation files into asn2country_all.txt (ASN -> Country).
#    - For RIPE, use the new .bz2 URL: https://ftp.ripe.net/ripe/stats/<year>/delegated-ripencc-extended-<date>.bz2
#    - For the others (ARIN, APNIC, LACNIC, AFRINIC), remain unchanged (uncompressed).
# 3) Download a RouteViews RIB if not present, parse into prefix2asn.txt (Prefix -> Origin ASN).
# 4) Combine asn2country_all.txt + prefix2asn.txt into prefix2country.txt (Prefix -> Country).
#
# Works on macOS (BSD date) and Linux (GNU date).
#
# Usage:
#   chmod +x build_asn_country_db.sh
#   ./build_asn_country_db.sh
#
# Outputs:
#   - asn2country_all.txt
#   - prefix2asn.txt
#   - prefix2country.txt
#   - prefix2countrydelegated.txt
#

set -euo pipefail

#################################
# 1) Determine the target DATE. #
#################################
if [ -n "${RIR_DATE:-}" ]; then
  # If user sets RIR_DATE manually, use it
  DATE="$RIR_DATE"
else
  # Auto-detect "yesterday" syntax on macOS vs. Linux
  if date -v-1d >/dev/null 2>&1; then
    # macOS (BSD date)
    DATE="$(date -v-1d +%Y%m%d)"
  else
    # Linux (GNU date)
    DATE="$(date -d 'yesterday' +%Y%m%d)"
  fi
fi

echo "Using date: $DATE"

##############################################
# 2) Configuration for RIR + RouteViews etc. #
##############################################
YEAR=${DATE:0:4}    # first 4 digits, e.g. 2025
MONTH=${DATE:4:2}   # next 2 digits, e.g. 01
DAY=${DATE:6:2}     # last 2 digits, e.g. 10

# ARIN, APNIC, LACNIC, AFRINIC remain unchanged in this example
# ARIN_FILE="delegated-arin-extended-${DATE}"
ARIN_FILE="delegated-arin-extended-latest"
ARIN_URL="https://ftp.arin.net/pub/stats/arin/${ARIN_FILE}"

APNIC_FILE="delegated-apnic-extended-latest"
APNIC_URL="https://ftp.apnic.net/apnic/stats/apnic/${APNIC_FILE}"

LACNIC_FILE="delegated-lacnic-extended-latest"
LACNIC_URL="https://ftp.lacnic.net/pub/stats/lacnic/${LACNIC_FILE}"

AFRINIC_FILE="delegated-afrinic-extended-latest"
AFRINIC_URL="https://ftp.afrinic.net/pub/stats/afrinic/${AFRINIC_FILE}"

RIPE_FILE="delegated-ripencc-extended-latest"
RIPE_URL="https://ftp.ripe.net/ripe/stats/${RIPE_FILE}"

# The final output for all RIR data -> asn2country.txt
ASN2COUNTRY="asn2country.txt"

# RouteViews RIB
RIB_FILE="rib.${DATE}.0000.bz2"
RIB_URL="http://routeviews.org/bgpdata/${YEAR}.${MONTH}/RIBS/${RIB_FILE}"
RIB_UNZIPPED="rib.${DATE}.0000"
RIB_TXT="bgp.out"

# Outputs
PREFIX2ASN="prefix2asn.txt"
PREFIX2COUNTRY="prefix2country.txt"
PREFIX2COUNTRY_TMP="prefix2country.tmp"
DELEGATED_PREFIX_COUNTRY="prefix2countrydelegated.txt"

################################
# 3) Functions                 #
################################

download_rirs() {
  for info in \
      "$ARIN_URL $ARIN_FILE" \
      "$APNIC_URL $APNIC_FILE" \
      "$LACNIC_URL $LACNIC_FILE" \
      "$RIPE_URL $RIPE_FILE" \
      "$AFRINIC_URL $AFRINIC_FILE"; do

    url=$(echo "$info" | awk '{print $1}')
    file=$(echo "$info" | awk '{print $2}')

    if [ -f "$file" ]; then
      echo "  Found existing file: $file (skipping download)"
    else
      echo "  Downloading $file from $url..."
      curl -f -O "$url" || {
        echo "Failed to download $url"
        exit 1
      }
    fi
  done
}

parse_rir_delegation() {
  echo "Parsing RIR files into $ASN2COUNTRY..."
  rm -f "$ASN2COUNTRY"

  # Process any file named "delegated-*-extended-<DATE>" (excluding .bz2)
  for file in delegated-*-latest; do
    # skip the compressed ones if they exist
    if [[ "$file" == *.bz2 ]]; then
      continue
    fi
    [ -f "$file" ] || continue

    echo "  Processing $file"
    # Format per line: registry|cc|type|start|value|date|status
    awk -F'|' '
      /^#/ || NF<7 { next }  # skip comments or incomplete
      $3 == "asn" && $2 != "*" {
        start_asn = $4 + 0
        count     = $5 + 0
        cc        = $2
        for(i=0; i<count; i++){
          print (start_asn + i) " " cc
        }
      }
    ' "$file" >> "$ASN2COUNTRY"
  done

  if [ -s "$ASN2COUNTRY" ]; then
    sort -n -k1 "$ASN2COUNTRY" | uniq > "${ASN2COUNTRY}.tmp"
    mv "${ASN2COUNTRY}.tmp" "$ASN2COUNTRY"
    echo "Created ASN->Country file: $ASN2COUNTRY"
  else
    echo "Warning: $ASN2COUNTRY is empty. No data parsed."
  fi
}

download_rib() {
  echo "Checking for RouteViews RIB dump: $RIB_FILE"
  if [ -f "$RIB_FILE" ]; then
    echo "  Found existing file: $RIB_FILE (skipping download)"
  else
    echo "  Downloading RIB from $RIB_URL..."
    curl -f -O "$RIB_URL" || {
      echo "Failed to download $RIB_URL"
      exit 1
    }
  fi
}

parse_rib() {
  echo "Decompressing $RIB_FILE..."
  if [ -f "$RIB_UNZIPPED" ]; then
    echo "  Detected $RIB_UNZIPPED already present, skipping decompression."
  else
    bunzip2 -kf "$RIB_FILE"
  fi

  echo "Running bgpdump -> $RIB_TXT..."
  bgpdump -v -m "$RIB_UNZIPPED" > "$RIB_TXT"

  echo "Building $PREFIX2ASN (prefix -> origin ASN)..."
  awk -F'|' '
    /^TABLE_DUMP2/ {
      prefix = $6
      as_path = $5
      split(as_path, arr, " ")
      origin_asn = arr[length(arr)]
      print prefix " " origin_asn
    }
  ' "$RIB_TXT" > "$PREFIX2ASN"

  echo "Wrote prefix->ASN mappings to $PREFIX2ASN"
}

build_prefix2country() {
  echo "Combining $PREFIX2ASN + $ASN2COUNTRY -> $PREFIX2COUNTRY..."

  if [ ! -s "$PREFIX2ASN" ]; then
    echo "Error: $PREFIX2ASN missing or empty."
    return 1
  fi
  if [ ! -s "$ASN2COUNTRY" ]; then
    echo "Error: $ASN2COUNTRY missing or empty."
    return 1
  fi

  awk '
    NR == FNR {
      # asn2country_all.txt line: "ASN COUNTRY"
      asn_cc[$1] = $2
      next
    }
    {
      # prefix2asn.txt line: "PREFIX ASN"
      prefix = $1
      asn    = $2
      cc     = asn_cc[asn]
      if (cc == "") cc="Unknown"
      print prefix, cc
    }
  ' "$ASN2COUNTRY" "$PREFIX2ASN" > "$PREFIX2COUNTRY_TMP"

  sort -u "$PREFIX2COUNTRY_TMP" > "$PREFIX2COUNTRY"
  rm -f "$PREFIX2COUNTRY_TMP"
  echo "Wrote prefix->Country mappings to $PREFIX2COUNTRY"
}

# We parse lines of the form:
#   <registry>|<cc>|<type>|<start>|<value>|<date>|<status>
# If <type> is 'ipv4' or 'ipv6' and <value> is a power of two, we convert to a prefix <start_ip>/<cidr>
# and output: <prefix> <cc>
# Note: We'll skip blocks that aren't powers-of-two. We won't subdivide them.

create_delegated_prefix_country() {
  echo "Creating $DELEGATED_PREFIX_COUNTRY from delegated data (only power-of-two allocations)..."
  rm -f "$DELEGATED_PREFIX_COUNTRY"

  # 1. Uses an arithmetic function is_power_of_two(x) that doubles 1 until it reaches or exceeds x.
  # 2. For IPv4, uses find_cidr4() to determine the CIDR.
  # 3. For IPv6, uses find_cidr6() to determine the CIDR.
  cat << 'EOF' > delegated_prefix_cc.awk
# Check if x is a power of two using arithmetic only.
function is_power_of_two(x) {
  if (x <= 0) return 0;
  y = 1;
  while (y < x) {
    y = y * 2;
  }
  return (y == x);
}

# For IPv4: find CIDR if count equals 2^(32 - p)
function find_cidr4(count,   p, power) {
  power = 1;
  p = 0;
  while (p <= 32 && power < count) {
    power = power * 2;
    p++;
  }
  if (power == count && p <= 32) {
    return 32 - p;
  }
  return -1;
}

# For IPv6: attempt to compute CIDR for count up to a reasonable limit.
function find_cidr6(count_str,   count, power, p) {
  count = count_str + 0;
  if (count_str != sprintf("%d", count)) {
    # Value too large to parse properly in AWK
    return -1;
  }
  power = 1;
  p = 0;
  while (p < 128 && power < count) {
    power = power * 2;
    p++;
  }
  if (power == count) {
    return 128 - p;
  }
  return -1;
}

BEGIN {
  # No initialization needed
}

# Process lines with at least 7 fields.
# Format: registry|cc|type|start|value|date|status
# Only consider lines where type is "ipv4" or "ipv6" and cc is not "*".
{
  if (NF >= 7 && $2 != "*" && ($3 == "ipv4" || $3 == "ipv6")) {
    cc = $2;
    start_ip = $4;
    val_str = $5;
    if ($3 == "ipv4") {
      count = val_str + 0;
      if (is_power_of_two(count)) {
        cidr = find_cidr4(count);
        if (cidr >= 0) {
          print start_ip "/" cidr, cc;
        }
      }
    } else if ($3 == "ipv6") {
      cidr6 = find_cidr6(val_str);
      if (cidr6 >= 0) {
        print start_ip "/" cidr6, cc;
      }
    }
  }
}
EOF

  # Process all delegated files (skipping any compressed ones) and append to the output file.
  for file in delegated-*-latest; do
    [[ "$file" =~ \.bz2$|\.gz$ ]] && continue
    [ -f "$file" ] || continue

    echo "  Checking IPv4/IPv6 blocks in $file"
    awk -F'|' -f delegated_prefix_cc.awk "$file" >> "$DELEGATED_PREFIX_COUNTRY"
  done

  # Sort and remove duplicates.
  if [ -s "$DELEGATED_PREFIX_COUNTRY" ]; then
    sort -u "$DELEGATED_PREFIX_COUNTRY" > "${DELEGATED_PREFIX_COUNTRY}.tmp"
    mv "${DELEGATED_PREFIX_COUNTRY}.tmp" "$DELEGATED_PREFIX_COUNTRY"
    echo "Wrote delegated-prefix-country.txt."
  else
    echo "No valid prefix lines found in delegated files."
    rm -f "$DELEGATED_PREFIX_COUNTRY"
  fi

  rm -f delegated_prefix_cc.awk
}

##################
# 4) Main Script #
##################
echo "=== Downloading latest RIR data ==="
download_rirs

echo "=== Parsing RIR data into $ASN2COUNTRY ==="
parse_rir_delegation

echo "=== Downloading & parsing RIB dump ==="
download_rib
parse_rib

echo "=== Building prefix->Country mapping ==="
build_prefix2country

echo "=== Building delegated prefix->Country mapping ==="
create_delegated_prefix_country

echo "=== Compressing files ==="
rm -rf *.bz2
bzip2 asn2country.txt
bzip2 prefix2asn.txt
bzip2 prefix2country.txt
bzip2 prefix2countrydelegated.txt

echo ""
echo "All done! Key outputs:"
echo "  - $ASN2COUNTRY   (ASN -> Country)"
echo "  - $PREFIX2ASN        (Prefix -> ASN)"
echo "  - $PREFIX2COUNTRY    (Prefix -> Country)"
echo "  - $DELEGATED_PREFIX_COUNTRY (Delegated Prefix -> Country)"
echo ""
