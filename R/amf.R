# Area Master File (AMF) reader.
#
# The 1976 and 1981 files are not a GIS format and no GDAL driver reads them:
# they are mainframe flat files, one fixed-width record per line with trailing
# blanks stripped, describing each street as a chain of nodes in NAD27 UTM.
# Everything the import needs is derived here, in R, and handed to DuckDB as
# WKT.
#
# A record is 113 bytes in 1976 and 95 in 1981. The difference is entirely the
# coordinates: 1981 is an EBCDIC original whose six coordinate pairs are packed
# decimal (COMP-3), two digits to the byte, which is exactly the 18 bytes the
# record loses (113 - 6 - 12 = 95). The deposit ships that file byte-for-byte
# as it was decoded to text through code page 037, so the packed fields survive
# as Latin-1 mojibake; re-encoding each character to cp037 restores the
# original byte, and cp037 is a bijection on 0-255 so nothing is lost on the
# way. See `cs_amf_unpack_comp3()`.
#
# Layout, 1-based and inclusive, common to both years:
#
#   1-4    CMA/CA code            18-19  feature class (blank = ordinary road)
#   5-8    area (census subdiv.)  20-21   map code
#   9-17   nine digits: feature * 1000 + sequence
#   25     record flag           27-30   node identifier
#   31     chain flag: B begins a chain, E ends it, blank continues
#
# and then, by year:
#
#            1976              1981
#   easting  32-38 (text)      32-35 (packed)
#   northing 39-45 (text)      36-39 (packed)
#   addresses 46-65            40-59     four 5-character fields
#   block reference points 66-93   60-75 two easting/northing pairs
#   cross-street area 94-97   76-79
#   cross-street feature+seq 98-106  80-88
#   cross-street name 107-111  89-93
#   cross-street type 112-113   94-95
#
# A record with sequence 0 is the feature header and carries the street name
# (27-46), type (47-48) and direction (49-50) in place of a coordinate. A
# record whose nine-digit number is under 1000 is not a feature at all but a
# file header: a map-sheet header when columns 5-8 are blank, which is where
# the UTM zone (37-38) comes from, and an area header otherwise, which names
# the census subdivision (22 onward). Detail records start at 100000, so the
# discriminant has four orders of magnitude of room.

# Column 5-8 of a map-sheet header is blank, and 37-38 carries the UTM zone.
# The datum is NAD27, verified rather than assumed: the 1976 node at Main and
# Hastings in Vancouver (492833, 5458561) transforms through EPSG:26710 to
# within 13 m of the intersection and through EPSG:26910 to 200 m away.
cs_amf_zone_crs <- function(zone) 26700L + as.integer(zone)

# Latin-1 byte -> the EBCDIC byte it was decoded from through code page 037.
cs_amf_ebcdic_table <- function() {
  as.raw(c(
    0x00, 0x01, 0x02, 0x03, 0x37, 0x2d, 0x2e, 0x2f, 0x16, 0x05, 0x25, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x3c, 0x3d, 0x32, 0x26, 0x18, 0x19, 0x3f, 0x27, 0x1c, 0x1d, 0x1e, 0x1f,
    0x40, 0x5a, 0x7f, 0x7b, 0x5b, 0x6c, 0x50, 0x7d, 0x4d, 0x5d, 0x5c, 0x4e, 0x6b, 0x60, 0x4b, 0x61,
    0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0x7a, 0x5e, 0x4c, 0x7e, 0x6e, 0x6f,
    0x7c, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6,
    0xd7, 0xd8, 0xd9, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xba, 0xe0, 0xbb, 0xb0, 0x6d,
    0x79, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96,
    0x97, 0x98, 0x99, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xc0, 0x4f, 0xd0, 0xa1, 0x07,
    0x20, 0x21, 0x22, 0x23, 0x24, 0x15, 0x06, 0x17, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x09, 0x0a, 0x1b,
    0x30, 0x31, 0x1a, 0x33, 0x34, 0x35, 0x36, 0x08, 0x38, 0x39, 0x3a, 0x3b, 0x04, 0x14, 0x3e, 0xff,
    0x41, 0xaa, 0x4a, 0xb1, 0x9f, 0xb2, 0x6a, 0xb5, 0xbd, 0xb4, 0x9a, 0x8a, 0x5f, 0xca, 0xaf, 0xbc,
    0x90, 0x8f, 0xea, 0xfa, 0xbe, 0xa0, 0xb6, 0xb3, 0x9d, 0xda, 0x9b, 0x8b, 0xb7, 0xb8, 0xb9, 0xab,
    0x64, 0x65, 0x62, 0x66, 0x63, 0x67, 0x9e, 0x68, 0x74, 0x71, 0x72, 0x73, 0x78, 0x75, 0x76, 0x77,
    0xac, 0x69, 0xed, 0xee, 0xeb, 0xef, 0xec, 0xbf, 0x80, 0xfd, 0xfe, 0xfb, 0xfc, 0xad, 0xae, 0x59,
    0x44, 0x45, 0x42, 0x46, 0x43, 0x47, 0x9c, 0x48, 0x54, 0x51, 0x52, 0x53, 0x58, 0x55, 0x56, 0x57,
    0x8c, 0x49, 0xcd, 0xce, 0xcb, 0xcf, 0xcc, 0xe1, 0x70, 0xdd, 0xde, 0xdb, 0xdc, 0x8d, 0x8e, 0xdf))
}

#' Byte offsets of the fields that move between the two AMF layouts
#'
#' @param packed `TRUE` for the 1981 layout, `FALSE` for 1976.
#' @return A list of 1-based inclusive `c(from, to)` pairs plus `width`.
#' @keywords internal
#' @noRd
cs_amf_layout <- function(packed) {
  if (packed) {
    list(width = 95L, packed = TRUE,
         x = c(32L, 35L), y = c(36L, 39L), addr = 40L, ref = 60L,
         xr_area = c(76L, 79L), xr_id = c(80L, 88L),
         xr_name = c(89L, 93L), xr_type = c(94L, 95L))
  } else {
    list(width = 113L, packed = FALSE,
         x = c(32L, 38L), y = c(39L, 45L), addr = 46L, ref = 66L,
         xr_area = c(94L, 97L), xr_id = c(98L, 106L),
         xr_name = c(107L, 111L), xr_type = c(112L, 113L))
  }
}

#' Split an AMF file into fixed-width records
#'
#' Records are newline-separated, but a 1981 packed coordinate byte can *be* a
#' newline: EBCDIC `0x25` decodes to LF through cp037, and the nibbles 2 and 5
#' are an ordinary mid-field digit pair. A naive split therefore tears records
#' apart. Rejoining is provable rather than heuristic: the only bytes that
#' decode to an ASCII digit are EBCDIC `0xF0`-`0xF9`, whose high nibble 15 is
#' not a decimal digit, so packed data can never open with four digits. A
#' fragment that does not start with four digits belongs to the record before
#' it, newline included.
#'
#' @param bytes The whole file as a raw vector.
#' @return A list of 1-based `start` and `end` byte offsets, one per record.
#' @keywords internal
#' @noRd
cs_amf_record_bounds <- function(bytes) {
  n_bytes <- length(bytes)
  nl <- which(bytes == as.raw(0x0a))
  starts <- c(1L, nl + 1L)
  ends <- c(nl - 1L, n_bytes)
  keep <- starts <= n_bytes & ends >= starts
  starts <- starts[keep]
  ends <- ends[keep]

  is_digit <- function(i) {
    b <- bytes[i]
    b >= as.raw(0x30) & b <= as.raw(0x39)
  }
  long_enough <- ends - starts + 1L >= 4L
  opens <- long_enough
  for (k in 0:3) opens <- opens & is_digit(pmin(starts + k, n_bytes))
  opens[1] <- TRUE

  idx <- which(opens)
  list(start = starts[idx], end = ends[c(idx[-1] - 1L, length(ends))])
}

#' Do the coordinate columns hold text rather than packed decimal?
#'
#' Measured over the records wide enough to reach column 45 and carrying no
#' blank there, which excludes the headers and the nodes with no coordinate.
#'
#' @param bytes The whole file as a raw vector.
#' @param bounds Output of [cs_amf_record_bounds()].
#' @return `TRUE` if the file is the 1976 text layout.
#' @keywords internal
#' @noRd
cs_amf_coords_are_text <- function(bytes, bounds) {
  span <- 32:45
  wide <- which(bounds$end - bounds$start + 1L >= max(span))
  if (!length(wide)) return(FALSE)
  b <- matrix(bytes[rep(bounds$start[wide], each = length(span)) +
                      rep(span - 1L, length(wide))], nrow = length(span))
  digit <- b >= as.raw(0x30) & b <= as.raw(0x39)
  blank <- b == as.raw(0x20)
  cand <- colSums(blank) == 0L
  if (!any(cand)) return(FALSE)
  mean(colSums(digit)[cand] == length(span)) > 0.5
}

#' Pad the records of an AMF file into a fixed-width raw matrix
#' @keywords internal
#' @noRd
cs_amf_record_matrix <- function(bytes, bounds, width) {
  starts <- bounds$start
  ends <- bounds$end
  n <- length(starts)
  lens <- pmin(ends - starts + 1L, width)
  off <- rep.int(seq_len(width) - 1L, n)
  st <- rep(starts, each = width)
  ok <- off < rep(lens, each = width)
  v <- rep(as.raw(0x20), n * width)
  v[ok] <- bytes[st[ok] + off[ok]]
  matrix(v, nrow = width, ncol = n)
}

#' Decode a packed-decimal (COMP-3) field out of the record matrix
#'
#' Two digits to the byte, with the low nibble of the last byte holding the
#' sign. A nibble above 9 in a digit position, or a sign nibble below 10, means
#' the field is not a number -- which is how the "no coordinate" sentinel
#' presents itself, since it is a run of EBCDIC blanks.
#'
#' @param m Record matrix from [cs_amf_record_matrix()].
#' @param from,to 1-based inclusive byte range.
#' @return A numeric vector, `NA` where the field does not decode.
#' @keywords internal
#' @noRd
cs_amf_unpack_comp3 <- function(m, from, to) {
  nb <- to - from + 1L
  e <- matrix(as.integer(cs_amf_ebcdic_table()[as.integer(m[from:to, ]) + 1L]),
              nrow = nb)
  hi <- e %/% 16L
  lo <- e %% 16L
  d <- matrix(0L, nrow = 2L * nb - 1L, ncol = ncol(e))
  for (i in seq_len(nb)) {
    d[2L * i - 1L, ] <- hi[i, ]
    if (i < nb) d[2L * i, ] <- lo[i, ]
  }
  sign_nibble <- lo[nb, ]
  val <- colSums(d * 10^((nrow(d) - 1L):0))
  val[sign_nibble == 13L] <- -val[sign_nibble == 13L]
  val[colSums(d > 9L) > 0L | sign_nibble < 10L] <- NA_real_
  val
}

# The 1976 coordinate sentinel. The file is the same EBCDIC record printed
# through a plain translation, so a blank COMP-3 field arrives as the digits of
# its blanks: 0x40 0x40 0x40 0x40 unpacks to 4040404.
cs_amf_null_coord <- "4040404"

#' Read one AMF coordinate field, either layout
#' @keywords internal
#' @noRd
cs_amf_coord <- function(m, recs, span, packed) {
  if (packed) return(cs_amf_unpack_comp3(m, span[1], span[2]))
  txt <- substr(recs, span[1], span[2])
  v <- suppressWarnings(as.numeric(txt))
  v[txt == cs_amf_null_coord] <- NA_real_
  v
}

# Blank and the underscore run are both "no value" here, on top of a field that
# may simply be short. Kept together so every text field is cleared the same
# way -- the same problem the shapefile vintages have with '', 'N/A' and '_'.
cs_amf_chr <- function(x) {
  x <- trimws(x)
  x[!nzchar(x) | grepl("^_+$", x)] <- NA_character_
  x
}

cs_amf_int <- function(x) {
  x <- cs_amf_chr(x)
  suppressWarnings(as.integer(x))
}

#' Parse an AMF file into its node records
#'
#' One row per node record, with the map sheet, area and feature attributes
#' already carried down onto it. This is the raw view of the file; the segments
#' [get_road_network()] serves are built from it by [cs_amf_segments()].
#'
#' @param path Path to an AMF `.data` file.
#' @return A [tibble::tibble()], one row per node record, in file order.
#' @keywords internal
#' @noRd
cs_amf_nodes <- function(path) {
  bytes <- readBin(path, "raw", n = file.info(path)$size)
  if (!length(bytes)) {
    stop("'", basename(path), "' is empty.", call. = FALSE)
  }

  # The layout is read off the file rather than supplied: the two releases hold
  # the same fields, and 1981 is exactly the 18 bytes shorter that packing six
  # coordinate pairs saves. Detecting on the presence of a high byte instead
  # would misread 1976, whose last feature header carries a few bytes of
  # trailing rubbish; detecting on width alone would misread a file whose
  # trailing cross-street fields happen to be blank throughout, since the
  # records are stored with their trailing blanks stripped. So width rules a
  # file in as 1976 when it exceeds 95 bytes, and the coordinate columns settle
  # the rest: 1976 writes them as fourteen ASCII digits, and packed data cannot
  # be, because only EBCDIC 0xF0-0xF9 decode to a digit and their high nibble,
  # 15, is not one.
  bounds <- cs_amf_record_bounds(bytes)
  widest <- max(bounds$end - bounds$start + 1L)
  if (widest > 113L) {
    stop("'", basename(path), "' holds records up to ", widest, " bytes; the ",
         "1976 and 1981 Area Master Files are 113 and 95. This file is not ",
         "one of them, or it is not the raw deposit.", call. = FALSE)
  }
  packed <- widest <= 95L && !cs_amf_coords_are_text(bytes, bounds)
  lay <- cs_amf_layout(packed)

  m <- cs_amf_record_matrix(bytes, bounds, lay$width)
  n <- ncol(m)

  # The text view must stay byte-for-byte positional, because every field is
  # read out of it by column. So everything outside printable ASCII is blanked
  # first: the packed coordinates are read from the raw matrix instead, and
  # what remains -- NUL filler in columns 22-24, six 1981 records with NULs in
  # the block reference points, and the trailing rubbish on 1976's last feature
  # header -- carries nothing.
  #
  # Blanking rather than re-encoding is the point. Marking the bytes `latin1`
  # and converting is what one would reach for, and it silently corrupts the
  # column positions: R converts through CP1252, whose 0x81, 0x8d, 0x8f, 0x90
  # and 0x9d are undefined and come back as a multi-character escape. A packed
  # easting of 0426133 is the bytes 0x9c 0x17 0x13 0x14, and the 0x8d in its
  # own block reference point three columns later pushed the cross-street name
  # of that record -- and only that record -- out of alignment.
  mt <- m
  mt[mt < as.raw(0x20) | mt > as.raw(0x7e)] <- as.raw(0x20)
  recs <- vapply(seq_len(n), function(i) rawToChar(mt[, i]), character(1))

  id <- suppressWarnings(as.numeric(substr(recs, 9L, 17L)))
  if (anyNA(id)) {
    stop("'", basename(path), "' has ", sum(is.na(id)), " record(s) without a ",
         "nine-digit feature number; this is not an Area Master File, or its ",
         "layout differs from the 1976 and 1981 releases.", call. = FALSE)
  }

  is_header <- id < 1000
  is_sheet <- is_header & !nzchar(trimws(substr(recs, 5L, 8L)))

  # Map sheets scope everything below them, and a (area, feature) pair repeats
  # across sheets -- the same trap the 1991 SNF sets with `arc_id`. Number them
  # so the feature key can be made unique.
  sheet <- cumsum(is_sheet)
  sheet_name <- cs_amf_chr(substr(recs, 39L, 58L))[is_sheet][pmax(sheet, 1L)]
  zone <- cs_amf_int(substr(recs, 37L, 38L))[is_sheet][pmax(sheet, 1L)]

  cma <- cs_amf_chr(substr(recs, 1L, 4L))
  area <- cs_amf_chr(substr(recs, 5L, 8L))

  # Area headers name the census subdivision. They are re-stated on every sheet
  # that touches the area, and the name is not always spelled the same way, so
  # the lookup is keyed on the sheet as well.
  ah <- is_header & !is_sheet
  area_key <- paste(sheet, area)
  area_name <- cs_amf_chr(substr(recs, 22L, 51L))[ah][
    match(area_key, area_key[ah])]

  feature <- as.integer(id %/% 1000)
  seq_no <- as.integer(id %% 1000)
  is_detail <- !is_header
  is_fhead <- is_detail & seq_no == 0L

  # A feature header immediately precedes its nodes, so the street name is
  # carried down by counting headers rather than by a join.
  fh <- cumsum(is_fhead)
  fh_idx <- which(is_fhead)
  pick <- function(x) if (length(fh_idx)) x[fh_idx][pmax(fh, 1L)] else NA_character_
  name <- pick(cs_amf_chr(substr(recs, 27L, 46L)))
  type <- pick(cs_amf_chr(substr(recs, 47L, 48L)))
  dir <- pick(cs_amf_chr(substr(recs, 49L, 50L)))

  keep <- is_detail & !is_fhead
  a <- lay$addr
  r <- lay$ref
  rw <- if (packed) 4L else 7L

  out <- tibble::tibble(
    sheet = sheet[keep],
    sheet_name = sheet_name[keep],
    zone = zone[keep],
    cma = cma[keep],
    area = area[keep],
    area_name = area_name[keep],
    feature = feature[keep],
    seq_no = seq_no[keep],
    class = cs_amf_chr(substr(recs, 18L, 19L))[keep],
    map_code = cs_amf_chr(substr(recs, 20L, 21L))[keep],
    node = cs_amf_chr(substr(recs, 27L, 30L))[keep],
    chain = substr(recs, 31L, 31L)[keep],
    name = name[keep],
    type = type[keep],
    dir = dir[keep],
    x = cs_amf_coord(m, recs, lay$x, packed)[keep],
    y = cs_amf_coord(m, recs, lay$y, packed)[keep],
    # The four address fields at a node are, in order, the civic number to the
    # left, to the right, from the left and from the right. A block face
    # between two nodes therefore takes its "from" values from the node it
    # starts at and its "to" values from the node it ends at -- verified on
    # Main Street in Vancouver, where Alexander to Powell resolves to 100-198
    # even and 101-199 odd, exactly the 100 block.
    addr_to_l = cs_amf_int(substr(recs, a, a + 4L))[keep],
    addr_to_r = cs_amf_int(substr(recs, a + 5L, a + 9L))[keep],
    addr_from_l = cs_amf_int(substr(recs, a + 10L, a + 14L))[keep],
    addr_from_r = cs_amf_int(substr(recs, a + 15L, a + 19L))[keep],
    # Two block reference points, one either side of the chain. Measured on
    # 1976 Vancouver they are on opposite sides 95.7% of the time, with the
    # first on the left 97.8% of the time, at a median 73 m from the node.
    ref_l_x = cs_amf_coord(m, recs, c(r, r + rw - 1L), packed)[keep],
    ref_l_y = cs_amf_coord(m, recs, c(r + rw, r + 2L * rw - 1L), packed)[keep],
    ref_r_x = cs_amf_coord(m, recs, c(r + 2L * rw, r + 3L * rw - 1L),
                           packed)[keep],
    ref_r_y = cs_amf_coord(m, recs, c(r + 3L * rw, r + 4L * rw - 1L),
                           packed)[keep],
    xref_area = cs_amf_chr(substr(recs, lay$xr_area[1], lay$xr_area[2]))[keep],
    xref_id = cs_amf_chr(substr(recs, lay$xr_id[1], lay$xr_id[2]))[keep],
    xref_name = cs_amf_chr(substr(recs, lay$xr_name[1],
                                  lay$xr_name[2]))[keep],
    xref_type = cs_amf_chr(substr(recs, lay$xr_type[1], lay$xr_type[2]))[keep]
  )
  # Records are not reliably in sequence order in the file: 19,645 of the
  # 45,933 node records in the 1981 BC file step backwards, with a chain's `E`
  # filed before its `B`. Left alone that shatters the chains -- 22,175 of them
  # instead of 6,834, and 40% of the segments lost. The sequence number is the
  # order, and it is spaced in tens precisely so records can be inserted, so
  # sorting on it is the file's own intent rather than a repair.
  out <- out[order(out$sheet, out$cma, out$area, out$feature, out$seq_no), ]
  attr(out, "amf_packed") <- packed
  out
}

#' Build block-face segments out of AMF node records
#'
#' A feature is a chain of nodes: `B` opens a chain, `E` closes it, and a blank
#' continues one. Each consecutive pair of nodes within a chain is one segment,
#' which is the granularity the address fields imply and, measured on 1976
#' Vancouver, gives a median segment length of 102 m -- a city block.
#'
#' @param nodes Output of [cs_amf_nodes()].
#' @return A [tibble::tibble()] with one row per segment and a `wkt` column.
#' @keywords internal
#' @noRd
cs_amf_segments <- function(nodes) {
  n <- nrow(nodes)
  if (n < 2L) return(nodes[0, ][, character(0)])

  prev <- c(NA_integer_, seq_len(n - 1L))
  same_feature <- !is.na(prev) &
    nodes$sheet == nodes$sheet[prev] &
    nodes$cma == nodes$cma[prev] &
    nodes$area == nodes$area[prev] &
    nodes$feature == nodes$feature[prev]
  # A chain break is a new feature, an explicit `B`, or the record after an
  # `E`. Features that carry neither -- the closed outlines of parks, which are
  # flagged `P` throughout -- fall out as a single chain, which is right.
  starts_chain <- !same_feature | nodes$chain == "B" |
    c(FALSE, nodes$chain[-n] == "E")
  chain <- cumsum(starts_chain)

  i <- seq_len(n - 1L)
  j <- i + 1L
  ok <- chain[i] == chain[j] &
    !is.na(nodes$x[i]) & !is.na(nodes$y[i]) &
    !is.na(nodes$x[j]) & !is.na(nodes$y[j]) &
    (nodes$x[i] != nodes$x[j] | nodes$y[i] != nodes$y[j])
  i <- i[ok]
  j <- j[ok]

  tibble::tibble(
    # A feature number is unique only within a map sheet -- the same trap the
    # 1991 SNF sets, where `arc_id` restarts in every urban unit -- so the
    # sheet is part of the identifier. That still leaves 22 collisions in the
    # 1981 BC file, whose six Victoria sheet headers are filed together ahead
    # of their data rather than each ahead of its own, so `(source_file,
    # source_id)` is the key to treat as unique and neither vintage may be
    # joined on `source_id` alone.
    source_id = sprintf("%02d-%s-%s-%06d-%03d", nodes$sheet[i], nodes$cma[i],
                        nodes$area[i], nodes$feature[i], nodes$seq_no[i]),
    sheet = nodes$sheet[i],
    sheet_name = nodes$sheet_name[i],
    zone = nodes$zone[i],
    cma = nodes$cma[i],
    area = nodes$area[i],
    area_name = nodes$area_name[i],
    node_from = nodes$node[i],
    node_to = nodes$node[j],
    name = nodes$name[i],
    type = nodes$type[i],
    dir = nodes$dir[i],
    class = nodes$class[i],
    af_l = nodes$addr_from_l[i],
    at_l = nodes$addr_to_l[j],
    af_r = nodes$addr_from_r[i],
    at_r = nodes$addr_to_r[j],
    epsg = cs_amf_zone_crs(nodes$zone[i]),
    wkt = sprintf("LINESTRING(%.0f %.0f, %.0f %.0f)",
                  nodes$x[i], nodes$y[i], nodes$x[j], nodes$y[j])
  )
}

#' Read a Statistics Canada Area Master File
#'
#' Parses a 1976 or 1981 Area Master File -- the mainframe flat file that
#' preceded the Street Network File -- into street segments. Each segment is
#' one block face: the piece of a street between two consecutive nodes of its
#' chain, carrying the street name, the feature class and the civic address
#' range on each side.
#'
#' No GIS driver reads this format, so the parser is part of this package. The
#' two releases differ only in how they store coordinates: 1976 writes them as
#' text, while 1981 is an EBCDIC file whose coordinates are packed decimal and
#' survive in the deposited copy as Latin-1 mojibake. Both are handled, and the
#' layout is detected from the file rather than supplied.
#'
#' Coordinates are NAD27 UTM in a zone that is stated per map sheet, so a file
#' can span zones. They are reprojected to EPSG:3347 (NAD83 / Statistics Canada
#' Lambert), which is the projection the rest of this package works in, so that
#' one file returns one geometry column.
#'
#' The data are distributed under the Statistics Canada Open Licence
#' (<https://www.statcan.gc.ca/en/reference/licence>).
#'
#' @param path Path to an Area Master File, conventionally named `.data`.
#' @param nodes Return the underlying node records instead of segments. The
#'   node view is one row per record as the file stores it, including the
#'   cross-street reference, the block reference points either side of the
#'   chain, and the chain flags -- everything the segment view collapses.
#'
#' @return An [sf::sf] tibble of `LINESTRING` segments in EPSG:3347, or, with
#'   `nodes = TRUE`, a plain [tibble::tibble()] of node records with `x` and `y`
#'   in their own UTM zone.
#'
#' @examples
#' \dontrun{
#' amf <- canstreet_download(1976)
#' segs <- read_amf(amf$path[1])
#' }
#' @export
read_amf <- function(path, nodes = FALSE) {
  if (length(path) != 1L || !file.exists(path)) {
    stop("`path` must name one existing Area Master File.", call. = FALSE)
  }
  recs <- cs_amf_nodes(path)
  if (nodes) return(recs)

  segs <- cs_amf_segments(recs)
  if (!nrow(segs)) {
    stop("'", basename(path), "' yielded no segments.", call. = FALSE)
  }

  # One file can span UTM zones, so the geometry is assembled zone by zone and
  # only then put in the common projection.
  geom <- vector("list", 0L)
  order_idx <- integer(0)
  for (e in sort(unique(segs$epsg))) {
    k <- which(segs$epsg == e)
    g <- sf::st_transform(sf::st_as_sfc(segs$wkt[k], crs = e), 3347)
    geom <- c(geom, list(g))
    order_idx <- c(order_idx, k)
  }
  geom <- do.call(c, geom)[order(order_idx)]
  sf::st_sf(segs[, setdiff(names(segs), "wkt")], geometry = geom)
}
