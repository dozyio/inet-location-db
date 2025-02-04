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
ARIN_FILE="delegated-arin-extended-${DATE}"
ARIN_URL="https://ftp.arin.net/pub/stats/arin/${ARIN_FILE}"

APNIC_FILE="delegated-apnic-extended-${DATE}.gz"
APNIC_FILE_UNZIP="delegated-apnic-extended-${DATE}"
APNIC_URL="https://ftp.apnic.net/apnic/stats/apnic/${YEAR}/${APNIC_FILE}"

LACNIC_FILE="delegated-lacnic-extended-${DATE}"
LACNIC_URL="https://ftp.lacnic.net/pub/stats/lacnic/${LACNIC_FILE}"

AFRINIC_FILE="delegated-afrinic-extended-${DATE}"
AFRINIC_URL="https://ftp.afrinic.net/pub/stats/afrinic/${YEAR}/${AFRINIC_FILE}"

RIPE_FILE="delegated-ripencc-extended-${DATE}.bz2"
RIPE_FILE_UNZIP="delegated-ripencc-extended-${DATE}"
RIPE_URL="https://ftp.ripe.net/ripe/stats/${YEAR}/${RIPE_FILE}"

# The final output for all RIR data -> asn2country_all.txt
ASN2COUNTRY_ALL="asn2country_all.txt"

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

# Download ARIN/LACNIC/AFRINIC if missing (uncompressed).
download_other_rirs() {
  for info in \
      "$ARIN_URL $ARIN_FILE" \
      "$LACNIC_URL $LACNIC_FILE" \
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

# Download the RIPE file if missing, then decompress to a .txt file
download_ripe() {
  if [ -f "$RIPE_FILE_UNZIP" ]; then
    echo "  Found existing uncompressed RIPE file: $RIPE_FILE_UNZIP (skipping download)"
    return
  fi

  if [ -f "$RIPE_FILE" ]; then
    echo "  Found existing compressed RIPE file: $RIPE_FILE"
  else
    echo "  Downloading $RIPE_FILE from $RIPE_URL..."
    curl -f -O "$RIPE_URL" || {
      echo "Failed to download $RIPE_URL"
      exit 1
    }
  fi

  echo "Decompressing $RIPE_FILE -> $RIPE_FILE_UNZIP..."
  # '-k' keeps the original .bz2; '-f' overwrites existing
  bunzip2 -kf "$RIPE_FILE"

  if [ ! -f "$RIPE_FILE_UNZIP" ]; then
    echo "Error: decompression failed, $RIPE_FILE_UNZIP not found."
    exit 1
  fi
}

# Download the APNIC file if missing, then decompress to a .txt file
download_apnic() {
  if [ -f "$APNIC_FILE_UNZIP" ]; then
    echo "  Found existing uncompressed APNIC file: $APNIC_FILE_UNZIP (skipping download)"
    return
  fi

  if [ -f "$APNIC_FILE" ]; then
    echo "  Found existing compressed APNIC file: $APNIC_FILE"
  else
    echo "  Downloading $APNIC_FILE from $APNIC_URL..."
    curl -f -O "$APNIC_URL" || {
      echo "Failed to download $APNIC_URL"
      exit 1
    }
  fi

  echo "Decompressing $APNIC_FILE -> $APNIC_FILE_UNZIP..."
  gunzip "$APNIC_FILE"
  # '-k' keeps the original .bz2; '-f' overwrites existing

  if [ ! -f "$APNIC_FILE_UNZIP" ]; then
    echo "Error: decompression failed, $APNIC_FILE_UNZIP not found."
    exit 1
  fi
}

parse_rir_delegation() {
  echo "Parsing RIR files into $ASN2COUNTRY_ALL..."
  rm -f "$ASN2COUNTRY_ALL"

  # Process any file named "delegated-*-extended-<DATE>" (excluding .bz2)
  for file in delegated-*-"${DATE}"; do
    # skip the compressed ones if they exist
    if [[ "$file" == *.bz2 ]]; then
      continue
    fi
    # ensure it's a real file
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
    ' "$file" >> "$ASN2COUNTRY_ALL"
  done

  if [ -s "$ASN2COUNTRY_ALL" ]; then
    sort -n -k1 "$ASN2COUNTRY_ALL" | uniq > "${ASN2COUNTRY_ALL}.tmp"
    mv "${ASN2COUNTRY_ALL}.tmp" "$ASN2COUNTRY_ALL"
    echo "Created ASN->Country file: $ASN2COUNTRY_ALL"
  else
    echo "Warning: $ASN2COUNTRY_ALL is empty. No data parsed."
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
  echo "Combining $PREFIX2ASN + $ASN2COUNTRY_ALL -> $PREFIX2COUNTRY..."

  if [ ! -s "$PREFIX2ASN" ]; then
    echo "Error: $PREFIX2ASN missing or empty."
    return 1
  fi
  if [ ! -s "$ASN2COUNTRY_ALL" ]; then
    echo "Error: $ASN2COUNTRY_ALL missing or empty."
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
  ' "$ASN2COUNTRY_ALL" "$PREFIX2ASN" > "$PREFIX2COUNTRY_TMP"

  sort -u "$PREFIX2COUNTRY_TMP" > "$PREFIX2COUNTRY"
  rm -f "$PREFIX2COUNTRY_TMP"
  echo "Wrote prefix->Country mappings to $PREFIX2COUNTRY"
}

########################################
#  New Function: delegated prefix->cc  #
########################################
# We parse lines of the form:
#   <registry>|<cc>|<type>|<start>|<value>|<date>|<status>
# If <type> is 'ipv4' or 'ipv6' and <value> is a power of two, we convert to a prefix <start_ip>/<cidr>
# and output: <prefix> <cc>
# Note: We'll skip blocks that aren't powers-of-two. We won't subdivide them.

create_delegated_prefix_country() {
  echo "Creating $DELEGATED_PREFIX_COUNTRY from delegated data (only power-of-two allocations)..."
  rm -f "$DELEGATED_PREFIX_COUNTRY"

  # Write an AWK script that:
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
  for file in delegated-*-"${DATE}"; do
    [[ "$file" =~ \.bz2$|\.gz$ ]] && continue
    [ -f "$file" ] || continue

    echo "  Checking IPv4/IPv6 blocks in $file"
    awk -F'|' -f delegated_prefix_cc.awk "$file" >> "$DELEGATED_PREFIX_COUNTRY"
  done

  # Sort and remove duplicates.
  if [ -s "$DELEGATED_PREFIX_COUNTRY" ]; then
    sort -u "$DELEGATED_PREFIX_COUNTRY" > "${DELEGATED_PREFIX_COUNTRY}.tmp"
    mv "${DELEGATED_PREFIX_COUNTRY}.tmp" "$DELEGATED_PREFIX_COUNTRY"
    echo "Wrote delegated-prefix-country.txt with IPv4/IPv6 power-of-two blocks."
  else
    echo "No valid prefix lines found in delegated files."
    rm -f "$DELEGATED_PREFIX_COUNTRY"
  fi

  rm -f delegated_prefix_cc.awk
}

##################
# 4) Main Script #
##################
echo "=== Downloading RIR data for date=$DATE ==="
download_other_rirs
download_ripe
download_apnic

echo "=== Parsing RIR data into $ASN2COUNTRY_ALL ==="
parse_rir_delegation

echo "=== Downloading & parsing RIB dump ==="
download_rib
parse_rib

echo "=== Building prefix->Country mapping ==="
build_prefix2country

echo "=== Building delegated prefix->Country file (new) ==="
create_delegated_prefix_country

echo ""
echo "All done! Key outputs:"
echo "  - $ASN2COUNTRY_ALL   (ASN -> Country)"
echo "  - $PREFIX2ASN        (Prefix -> ASN)"
echo "  - $PREFIX2COUNTRY    (Prefix -> Country)"
echo "  - $DELEGATED_PREFIX_COUNTRY (Delegated Prefix -> Country)"
echo ""
