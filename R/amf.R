# Area Master File (AMF) reader.
#
# The 1971 to 1986 files are not a GIS format and no GDAL driver reads them:
# they are mainframe flat files, one fixed-width record per line with trailing
# blanks stripped, describing each street as a chain of nodes in NAD27 UTM.
# Everything the import needs is derived here, in R, and handed to DuckDB as
# WKT.
#
# The record is documented in "The Area Master File User Guide", Geography
# Division, Statistics Canada, January 1988, which the hosted archives carry
# beside the data (`cs_sources()` says where they are). One AMF is one
# municipality, or a few, of a census metropolitan area or agglomeration, and
# it holds, in this order, a file heading, one record per municipality, and
# then the features: a header record followed by its detail records, one per
# node.
#
# The same record survives in three transcriptions, and they differ only in how
# the six coordinates are written. The original is EBCDIC with each
# coordinate in four bytes of packed decimal (COMP-3):
#
#   packed  95 bytes   the EBCDIC original decoded to text through code page
#                      037, so the packed fields survive as Latin-1 mojibake;
#                      re-encoding each character to cp037 restores the
#                      original byte, and cp037 is a bijection on 0-255 so
#                      nothing is lost on the way. See `cs_amf_unpack_comp3()`.
#                      The 1981 British Columbia deposit on Abacus.
#   text    113 bytes  each packed field printed as its seven digits, which is
#                      the 18 bytes the packed record saves (113 - 6 * 3 = 95).
#                      The 1976 British Columbia deposit on Abacus.
#   wide    119 bytes  each packed field printed as eight digits, the seven and
#                      a leading zero, lines ending CR LF. The national files
#                      Statistics Canada delivered for 1971, 1976, 1981 and
#                      1986, which is what the manifest serves.
#
# The guide documents a fourth, the 110-byte ASCII release of 1986 with a
# six-digit easting; no file seen here is in it.
#
# Layout, 1-based and inclusive, common to all three:
#
#   1-4    metropolitan area code: province (2) + area (2)
#   5-8    municipality code; blank on the file heading
#   9-14   feature code; blank on a municipality record
#   15-17  sequence: 000 on a feature header, ascending on its detail records
#   18     feature type           19     sub-feature type (together, `class`)
#   20-21  section number         22-24  binary filler
#   27-30  node number            31     node type: B begins a chain, E ends
#                                        it, P is a point feature, blank
#                                        continues
#
# and then, by transcription:
#
#                            packed    text      wide
#   easting                  32-35     32-38     32-39
#   northing                 36-39     39-45     40-47
#   addresses (4 x 5 chars)  40-59     46-65     48-67
#   block centroids (2 x,y)  60-75     66-93     68-99
#   cross-street municipality 76-79    94-97     100-103
#   cross-street feature+seq 80-88     98-106    104-112
#   cross-street name        89-93     107-111   113-117
#   cross-street type        94-95     112-113   118-119
#
# A feature header carries the name (27-46), the street type (47-48) and the
# direction (49-50) in place of a coordinate. The file heading carries the UTM
# zone (36-38) and the file's name (39-58); a municipality record names the
# municipality from column 22 -- in twenty characters in the national files,
# which follow it with a count, and in up to thirty in the Abacus deposits,
# which spell `GREATER VANCOUVER SUBD A` out.
#
# The feature code is a number written two ways: right-justified in the Abacus
# deposits, as the guide says it should be, and left-justified in the national
# files. `1000  ` and `  1000` are both feature 1000 -- the national files are
# in ascending numeric order under that reading and under no other -- so it is
# parsed as a number and never compared as a string.
#
# Record types are told apart the way the guide tells them apart, with three
# allowances for what the files actually hold. A municipality record's feature
# code is "spaces" in the guide and carries a count in the national files --
# one or two digits, and six in Stoney Creek 1986 -- so a feature code is
# three digits or more, which every real one is, and a record between a
# heading and the first feature header under it that has no node number is a
# municipality record whatever its columns 9-14 say. The node number is what
# keeps that from reaching the 1981 Abacus deposit, where detail records are
# filed ahead of their header straight after a heading. And the first record
# of a file is its heading whatever its columns 5-8 say: Kingston Township
# 1976 has part of the name written over them.
#
# The metropolitan area code is the heading's, not the record's. A record
# inserted in a later update carries the code of whoever keyed it: five
# records each in Beauport and St-Bruno 1976 say `2406` under a `2407` and a
# `2409` heading, nine in North Vancouver District 1976 say `5037` for `5937`,
# and every one sits between two records of the feature it belongs to. Read
# off the record, each would break its chain in two places.
#
# Four things in the national files are damage rather than format, and each
# is repaired where it is read rather than refused, because a refusal would
# cost a whole municipality:
#
#   - Fifteen St. Catharines 1976 records have their first eight bytes
#     overwritten with the name of the next municipality (`PELHAM  `), and
#     take the codes of the record before them.
#   - Nineteen of the 1981 files -- all five of Winnipeg's among them -- had
#     their feature headers put through the conversion meant for detail
#     records, 9,039 headers in all. It read columns 32-39 of the name as two
#     packed coordinates, printed each as `       .`, and so destroyed
#     characters 6 to 13 of every name; what followed it copied as four
#     five-character address fields, each left-justified, which is where the
#     street type and direction now are. The type and direction are recovered
#     (`cs_amf_damaged_header()`); the name is not a name any more -- `BRIDG`
#     is Bridge Street and `BIRCH` is Birch -- and is missing rather than
#     guessed at. It cannot be looked up by feature code in another release
#     either, because the codes are reassigned between them: of the damaged
#     headers whose code exists in 1976, 87% open with the same five
#     characters there, and in 1986 12%.
#   - A handful of coordinates are not numbers and become missing.
#   - What matches no record type is dropped and counted in the
#     `amf_unreadable` attribute.

# Column 5-8 of a file heading is blank, and 36-38 carries the UTM zone --
# right-justified in the Abacus deposits and either zero-padded or
# left-justified in the national files, so it is read as a number.
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

#' Byte offsets of the fields that move between the AMF transcriptions
#'
#' @param layout `"packed"`, `"text"` or `"wide"`; see the header of this file.
#' @return A list of 1-based inclusive `c(from, to)` pairs, the record `width`
#'   and the `coord_width` of one coordinate field.
#' @keywords internal
#' @noRd
cs_amf_layout <- function(layout) {
  switch(
    layout,
    packed = list(layout = "packed", width = 95L, coord_width = 4L,
                  muni = c(22L, 51L), x = c(32L, 35L), y = c(36L, 39L),
                  addr = 40L, ref = 60L,
                  xr_area = c(76L, 79L), xr_id = c(80L, 88L),
                  xr_name = c(89L, 93L), xr_type = c(94L, 95L)),
    text = list(layout = "text", width = 113L, coord_width = 7L,
                muni = c(22L, 51L), x = c(32L, 38L), y = c(39L, 45L),
                addr = 46L, ref = 66L,
                xr_area = c(94L, 97L), xr_id = c(98L, 106L),
                xr_name = c(107L, 111L), xr_type = c(112L, 113L)),
    wide = list(layout = "wide", width = 119L, coord_width = 8L,
                muni = c(22L, 41L), x = c(32L, 39L), y = c(40L, 47L),
                addr = 48L, ref = 68L,
                xr_area = c(100L, 103L), xr_id = c(104L, 112L),
                xr_name = c(113L, 117L), xr_type = c(118L, 119L)),
    stop("Unknown Area Master File layout '", layout, "'.", call. = FALSE))
}

#' Split an AMF file into fixed-width records
#'
#' Records are newline-separated, but a packed coordinate byte can *be* a
#' newline: EBCDIC `0x25` decodes to LF through cp037, and the nibbles 2 and 5
#' are an ordinary mid-field digit pair. A naive split therefore tears records
#' apart. Rejoining is provable rather than heuristic: the only bytes that
#' decode to an ASCII digit are EBCDIC `0xF0`-`0xF9`, whose high nibble 15 is
#' not a decimal digit, so packed data can never open with four digits. A
#' fragment that does not start with four digits belongs to the record before
#' it, newline included.
#'
#' That rule is for the packed transcription only. A text record cannot hold a
#' newline, so there a line is a record whatever it opens with -- and it has to
#' be, because the fifteen damaged St. Catharines records open with `PELH` and
#' rejoining would fold each into the record before it. `rejoin = FALSE` is
#' that plain split, and it drops the carriage return the national files end
#' their lines with.
#'
#' @param bytes The whole file as a raw vector.
#' @param rejoin Put back together the records a packed newline tore apart.
#' @return A list of 1-based `start` and `end` byte offsets, one per record.
#' @keywords internal
#' @noRd
cs_amf_record_bounds <- function(bytes, rejoin = TRUE) {
  n_bytes <- length(bytes)
  nl <- which(bytes == as.raw(0x0a))
  starts <- c(1L, nl + 1L)
  ends <- c(nl - 1L, n_bytes)
  keep <- starts <= n_bytes & ends >= starts
  starts <- starts[keep]
  ends <- ends[keep]

  if (!rejoin) {
    cr <- bytes[ends] == as.raw(0x0d)
    ends[cr] <- ends[cr] - 1L
    keep <- ends >= starts
    return(list(start = starts[keep], end = ends[keep]))
  }

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

#' Which transcription of the record a file is in
#'
#' Read off the coordinate columns rather than supplied, and not off the record
#' width: records are stored with their trailing blanks stripped, so a file
#' whose cross-street fields happen to be blank throughout is narrower than its
#' layout. Nor off the presence of a high byte, which the text files also carry
#' in their binary filler and in a few bytes of trailing rubbish.
#'
#' Columns 32-45 are coordinate digits in both text transcriptions and cannot
#' be in the packed one, because only EBCDIC `0xF0`-`0xF9` decode to a digit
#' and their high nibble, 15, is not one. Between the two text transcriptions
#' the easting decides: a UTM easting has six digits, so the seven-digit field
#' opens with one zero and the eight-digit field with two, and the "no
#' coordinate" sentinels keep to that -- `4040404` and `00000000`.
#'
#' Measured over the lines wide enough to reach column 45 and carrying no blank
#' there, which excludes the headers and most nodes with no coordinate. A packed
#' file is measured on lines its packed newlines have torn, which does not
#' matter: no fragment of it is fourteen digits either.
#'
#' @param bytes The whole file as a raw vector.
#' @param lines Output of `cs_amf_record_bounds(bytes, rejoin = FALSE)`.
#' @return `"packed"`, `"text"` or `"wide"`.
#' @keywords internal
#' @noRd
cs_amf_detect_layout <- function(bytes, lines) {
  span <- 32:45
  wide <- which(lines$end - lines$start + 1L >= max(span))
  if (!length(wide)) return("packed")
  b <- matrix(bytes[rep(lines$start[wide], each = length(span)) +
                      rep(span - 1L, length(wide))], nrow = length(span))
  digit <- b >= as.raw(0x30) & b <= as.raw(0x39)
  blank <- b == as.raw(0x20)
  cand <- colSums(blank) == 0L
  if (!any(cand)) return("packed")
  digits <- colSums(digit) == length(span)
  if (mean(digits[cand]) <= 0.5) return("packed")
  zero <- as.raw(0x30)
  two <- b[1L, digits] == zero & b[2L, digits] == zero
  if (mean(two) > 0.5) "wide" else "text"
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
#' @param m Record matrix from `cs_amf_record_matrix()`.
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

# The text coordinate sentinels. Both text transcriptions are the same EBCDIC
# record printed digit by digit, so a blank COMP-3 field arrives in the
# seven-digit one as the digits of its blanks -- 0x40 0x40 0x40 0x40 unpacks to
# 4040404 -- and in the eight-digit one, whose writer knew a blank field when
# it saw one, as zeros. Zero is no coordinate in any transcription: nothing in
# a UTM zone is at easting or northing 0.
cs_amf_null_coord <- c("4040404", "04040404")

#' Read one AMF coordinate field, any layout
#' @keywords internal
#' @noRd
cs_amf_coord <- function(m, recs, span, lay) {
  if (identical(lay$layout, "packed")) {
    return(cs_amf_unpack_comp3(m, span[1], span[2]))
  }
  txt <- substr(recs, span[1], span[2])
  # Digits and nothing else: `as.numeric()` alone would read a stray `1E5` as
  # a hundred thousand.
  v <- rep(NA_real_, length(txt))
  ok <- grepl("^[0-9]+$", txt) & !txt %in% cs_amf_null_coord
  v[ok] <- as.numeric(txt[ok])
  v[!is.na(v) & v == 0] <- NA_real_
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

# List B of the guide: the street types a feature header may carry.
cs_amf_street_types <- function() {
  c("AL", "AU", "AV", "BA", "BP", "BV", "CA", "CH", "CL", "CN", "CO", "CR",
    "CS", "CT", "DR", "GN", "GR", "GT", "GV", "HL", "HT", "HY", "JA", "LI",
    "LK", "LN", "ME", "MO", "PL", "PM", "PR", "PU", "PY", "RD", "RG", "RI",
    "RL", "RO", "RU", "RW", "SQ", "ST", "TL", "TR", "VW", "WK", "WY")
}

#' Recover the street type and direction from a damaged feature header
#'
#' The headers the header of this file describes as put through the detail
#' conversion. Columns 32-47 are the two failed coordinates; the original
#' columns 40-59 follow as four five-character fields, each left-justified, so
#' the tail of the name (original 40-44) is in 48-52, the last two characters
#' of the name with the type and the first character of the direction
#' (original 45-49) in 53-57, and the second character of the direction
#' (original 50) opens 58-62. The direction is right-justified in its two
#' columns, so `ST` and `E` is the common case, `RDS` and `W` is Road
#' South-West, and a four-character `WIST` is a name that ran to the end of its
#' field ahead of `ST`.
#'
#' Left-justifying is what makes a two-character field ambiguous: `ST` after a
#' short name, or the last two characters of a twenty-character name that has
#' no type, which is what a boundary called `WINNIPEG CITY LIMITS` leaves
#' (`TS`). So a type is kept only when it is one of the guide's street types.
#' Seven of the nineteen files are British Columbia's, which Abacus holds
#' undamaged; over the 1,733 headers that can be paired with certainty the
#' direction is right on every one and the type on all but eight, each a
#' pairing that was not the same feature after all.
#'
#' @param recs The records as blanked, fixed-width text.
#' @return A list of `damaged`, a logical per record, and the `type` and `dir`
#'   read out of the damaged ones.
#' @keywords internal
#' @noRd
cs_amf_damaged_header <- function(recs) {
  damaged <- substr(recs, 32L, 47L) == "       .       ."
  f2 <- trimws(substr(recs, 53L, 57L))
  f3 <- trimws(substr(recs, 58L, 62L))
  n2 <- nchar(f2)
  type <- ifelse(n2 >= 4L, substr(f2, 3L, 4L),
                 ifelse(n2 >= 2L, substr(f2, 1L, 2L), ""))
  type[!type %in% cs_amf_street_types()] <- ""
  dir <- paste0(ifelse(n2 == 3L | n2 == 5L, substr(f2, n2, n2), ""),
                substr(f3, 1L, 1L))
  list(damaged = damaged, type = type, dir = dir)
}

#' Parse an AMF file into its node records
#'
#' One row per node record, with the file heading, municipality and feature
#' attributes already carried down onto it. This is the raw view of the file;
#' the segments [get_road_network()] serves are built from it by
#' `cs_amf_segments()`.
#'
#' @param path Path to an Area Master File.
#' @return A [tibble::tibble()], one row per node record, in sequence order,
#'   with the transcription in its `amf_layout` attribute and the number of
#'   records that matched no record type in `amf_unreadable`.
#' @keywords internal
#' @noRd
cs_amf_nodes <- function(path) {
  bytes <- readBin(path, "raw", n = file.info(path)$size)
  if (!length(bytes)) {
    stop("'", basename(path), "' is empty.", call. = FALSE)
  }

  # The layout is read off the file rather than supplied; see
  # `cs_amf_detect_layout()`. Only then can the file be cut into records,
  # because only the packed transcription needs its lines rejoined and only the
  # text ones can afford not to be. The seven-digit transcription keeps the
  # rejoin it has always had: the Abacus 1976 deposit ends in a few bytes of
  # rubbish, which that folds into the last record rather than making a record
  # of.
  lines <- cs_amf_record_bounds(bytes, rejoin = FALSE)
  lay <- cs_amf_layout(cs_amf_detect_layout(bytes, lines))
  bounds <- if (identical(lay$layout, "wide")) {
    lines
  } else {
    cs_amf_record_bounds(bytes)
  }
  widest <- max(bounds$end - bounds$start + 1L)
  if (widest > lay$width) {
    stop("'", basename(path), "' holds records up to ", widest, " bytes; an ",
         "Area Master File record is 95, 113 or 119, and this file reads as ",
         "the ", lay$width, "-byte kind. This file is not one of them, or it ",
         "is not the raw deposit.", call. = FALSE)
  }

  m <- cs_amf_record_matrix(bytes, bounds, lay$width)
  n <- ncol(m)

  # The text view must stay byte-for-byte positional, because every field is
  # read out of it by column. So everything outside printable ASCII is blanked
  # first: the packed coordinates are read from the raw matrix instead, and
  # what remains -- the binary filler in columns 22-24, six packed records with
  # NULs in the block centroids, and the trailing rubbish on the Abacus 1976
  # deposit's last feature header -- carries nothing.
  #
  # Blanking rather than re-encoding is the point. Marking the bytes `latin1`
  # and converting is what one would reach for, and it silently corrupts the
  # column positions: R converts through CP1252, whose 0x81, 0x8d, 0x8f, 0x90
  # and 0x9d are undefined and come back as a multi-character escape. A packed
  # easting of 0426133 is the bytes 0x9c 0x17 0x13 0x14, and the 0x8d in its
  # own block centroid three columns later pushed the cross-street name of that
  # record -- and only that record -- out of alignment.
  mt <- m
  mt[mt < as.raw(0x20) | mt > as.raw(0x7e)] <- as.raw(0x20)
  recs <- vapply(seq_len(n), function(i) rawToChar(mt[, i]), character(1))

  # Record types, as the guide keys them: a file heading has no municipality
  # code, a municipality record no feature code, a feature header sequence 000
  # and a detail record a sequence above it. See the header of this file for
  # why a feature code is three digits or more and the first record is a
  # heading regardless.
  code <- trimws(substr(recs, 9L, 14L))
  seq_txt <- substr(recs, 15L, 17L)
  has_seq <- grepl("^[0-9]{3}$", seq_txt)
  is_sheet <- !nzchar(trimws(substr(recs, 5L, 8L)))
  is_feature <- !is_sheet & has_seq & grepl("^[0-9]{3,6}$", code)
  if (!is_feature[1]) is_sheet[1] <- TRUE
  # Between a heading and the first feature header under it, a record with no
  # node number is a municipality record, whatever it carries where a feature
  # code would be.
  sheet <- cumsum(is_sheet)
  opened <- stats::ave(is_feature & seq_txt == "000", sheet, FUN = cumsum) > 0
  has_node <- grepl("^[0-9]{4}$", substr(recs, 27L, 30L))
  is_feature <- is_feature & (opened | has_node)
  if (!any(is_feature)) {
    stop("'", basename(path), "' has no record carrying a feature code and a ",
         "sequence number; this is not an Area Master File, or its layout is ",
         "not one of them that this package reads.", call. = FALSE)
  }

  feature <- rep(NA_integer_, n)
  feature[is_feature] <- as.integer(code[is_feature])
  seq_no <- rep(NA_integer_, n)
  seq_no[has_seq] <- as.integer(seq_txt[has_seq])
  is_feature <- is_feature & feature > 0L
  is_fhead <- is_feature & seq_no == 0L
  is_detail <- is_feature & seq_no > 0L

  # A file heading scopes everything below it, and a (municipality, feature)
  # pair repeats across the headings of a file that holds several -- the same
  # trap the 1991 SNF sets with `arc_id`. Number them so the feature key can be
  # made unique. The national files hold one heading each.
  sheet_name <- cs_amf_chr(substr(recs, 39L, 58L))[is_sheet][pmax(sheet, 1L)]
  zone <- cs_amf_int(substr(recs, 36L, 38L))[is_sheet][pmax(sheet, 1L)]

  # Both codes are digits throughout. A record whose first eight bytes are not
  # has had them overwritten, and sits among the records of the feature it
  # belongs to, so it takes the municipality of the last record that has one.
  # The metropolitan area is the heading's; see the header of this file.
  coded <- grepl("^[0-9]{8}", recs)
  from <- cummax(ifelse(coded, seq_len(n), 0L))
  from[from == 0L] <- NA_integer_
  area <- substr(recs, 5L, 8L)[from]
  cma <- substr(recs, 1L, 4L)[is_sheet][pmax(sheet, 1L)]
  own <- !grepl("^[0-9]{4}$", cma)
  cma[own] <- substr(recs, 1L, 4L)[from][own]
  cma[is_sheet] <- cs_amf_chr(substr(recs[is_sheet], 1L, 4L))

  # Municipality records name the census subdivision. They are re-stated under
  # every heading that touches the municipality, and the name is not always
  # spelled the same way, so the lookup is keyed on the heading as well.
  ah <- !is_sheet & !is_feature & coded
  area_key <- paste(sheet, area)
  area_name <- cs_amf_chr(substr(recs, lay$muni[1], lay$muni[2]))[ah][
    match(area_key, area_key[ah])]

  # A feature header immediately precedes its nodes, so the street name is
  # carried down by counting headers rather than by a join.
  fh <- cumsum(is_fhead)
  fh_idx <- which(is_fhead)
  pick <- function(x) c(NA_character_, x[fh_idx])[fh + 1L]
  h_name <- substr(recs, 27L, 46L)
  h_type <- substr(recs, 47L, 48L)
  h_dir <- substr(recs, 49L, 50L)
  dmg <- cs_amf_damaged_header(recs)
  bad <- is_fhead & dmg$damaged
  h_name[bad] <- ""
  h_type[bad] <- dmg$type[bad]
  h_dir[bad] <- dmg$dir[bad]
  name <- pick(cs_amf_chr(h_name))
  type <- pick(cs_amf_chr(h_type))
  dir <- pick(cs_amf_chr(h_dir))

  # An alias feature (`DA`) is a second name for a street, not a street: its
  # one detail record carries the original feature's name and codes where a
  # node's number and coordinate would be, so it is no node and is left out.
  # Upper-cased: three 1986 features are typed `e` for `E`.
  class <- cs_amf_chr(toupper(substr(recs, 18L, 19L)))
  keep <- is_detail & !(class %in% "DA") & !is.na(from)
  a <- lay$addr
  r <- lay$ref
  rw <- lay$coord_width

  out <- tibble::tibble(
    sheet = sheet[keep],
    sheet_name = sheet_name[keep],
    zone = zone[keep],
    cma = cma[keep],
    area = area[keep],
    area_name = area_name[keep],
    feature = feature[keep],
    seq_no = seq_no[keep],
    class = class[keep],
    map_code = cs_amf_chr(substr(recs, 20L, 21L))[keep],
    node = cs_amf_chr(substr(recs, 27L, 30L))[keep],
    chain = substr(recs, 31L, 31L)[keep],
    name = name[keep],
    type = type[keep],
    dir = dir[keep],
    x = cs_amf_coord(m, recs, lay$x, lay)[keep],
    y = cs_amf_coord(m, recs, lay$y, lay)[keep],
    # The four address fields at a node are, in order, the civic number to the
    # left, to the right, from the left and from the right -- the guide's
    # "before" and "after" the node. A block face between two nodes therefore
    # takes its "from" values from the node it starts at and its "to" values
    # from the node it ends at -- verified on Main Street in Vancouver, where
    # Alexander to Powell resolves to 100-198 even and 101-199 odd, exactly the
    # 100 block.
    addr_to_l = cs_amf_int(substr(recs, a, a + 4L))[keep],
    addr_to_r = cs_amf_int(substr(recs, a + 5L, a + 9L))[keep],
    addr_from_l = cs_amf_int(substr(recs, a + 10L, a + 14L))[keep],
    addr_from_r = cs_amf_int(substr(recs, a + 15L, a + 19L))[keep],
    # Two block-face centroids, one either side of the chain, each set back
    # from the midpoint of the block face that ends at this node. Measured on
    # 1976 Vancouver they are on opposite sides 95.7% of the time, with the
    # first on the left 97.8% of the time, at a median 73 m from the node.
    ref_l_x = cs_amf_coord(m, recs, c(r, r + rw - 1L), lay)[keep],
    ref_l_y = cs_amf_coord(m, recs, c(r + rw, r + 2L * rw - 1L), lay)[keep],
    ref_r_x = cs_amf_coord(m, recs, c(r + 2L * rw, r + 3L * rw - 1L),
                           lay)[keep],
    ref_r_y = cs_amf_coord(m, recs, c(r + 3L * rw, r + 4L * rw - 1L),
                           lay)[keep],
    xref_area = cs_amf_chr(substr(recs, lay$xr_area[1], lay$xr_area[2]))[keep],
    xref_id = cs_amf_chr(substr(recs, lay$xr_id[1], lay$xr_id[2]))[keep],
    xref_name = cs_amf_chr(substr(recs, lay$xr_name[1],
                                  lay$xr_name[2]))[keep],
    xref_type = cs_amf_chr(substr(recs, lay$xr_type[1], lay$xr_type[2]))[keep]
  )
  # Records are not reliably in sequence order in the file: 19,645 of the
  # 45,933 node records in the Abacus 1981 BC file step backwards, with a
  # chain's `E` filed before its `B`. Left alone that shatters the chains --
  # 22,175 of them instead of 6,834, and 40% of the segments lost. The
  # sequence number is the order, and it is spaced in tens precisely so
  # records can be inserted, so sorting on it is the file's own intent rather
  # than a repair.
  out <- out[order(out$sheet, out$cma, out$area, out$feature, out$seq_no), ]
  attr(out, "amf_layout") <- lay$layout
  attr(out, "amf_unreadable") <- sum(!is_sheet & !is_feature & !(ah & has_seq))
  out
}

#' Build block-face segments out of AMF node records
#'
#' A feature is a chain of nodes: `B` opens a chain, `E` closes it, and a blank
#' continues one. Each consecutive pair of nodes within a chain is one segment,
#' which is the granularity the address fields imply and, measured on 1976
#' Vancouver, gives a median segment length of 102 m -- a city block.
#'
#' @param nodes Output of `cs_amf_nodes()`.
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
    # Abacus 1981 BC file, whose six Victoria sheet headers are filed together
    # ahead of their data rather than each ahead of its own. The national
    # files hold one heading each and have none, but a vintage is many files,
    # so `(source_file, source_id)` is the key to treat as unique and no
    # vintage may be joined on `source_id` alone.
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
#' Parses an Area Master File -- the mainframe flat file that preceded the
#' Street Network File, released for the 1971, 1976, 1981 and 1986 censuses --
#' into street segments. Each segment is one block face: the piece of a street
#' between two consecutive nodes of its chain, carrying the street name, the
#' feature class and the civic address range on each side.
#'
#' No GIS driver reads this format, so the parser is part of this package. One
#' file is one municipality, or a few. The record survives in three
#' transcriptions that differ only in how they store coordinates -- as packed
#' decimal out of the EBCDIC original, or printed as seven or as eight digits
#' -- and all three are handled, the layout being detected from the file
#' rather than supplied. The national files [canstreet_download()] fetches are
#' the eight-digit kind.
#'
#' Coordinates are NAD27 UTM in a zone that is stated in the file heading. They
#' are reprojected to EPSG:3347 (NAD83 / Statistics Canada Lambert), which is
#' the projection the rest of this package works in, so that every file returns
#' the same geometry column.
#'
#' This is the file as it is: `class` is the two-character feature type and
#' sub-type and `type` the street type, uncombined and unlabelled. The
#' harmonized, labelled view of a whole vintage is [get_road_network()].
#'
#' Nineteen of the 1981 files carry feature headers whose street name was
#' destroyed before the files were delivered. Their segments are returned with
#' a missing `name`; geometry, class and address ranges are unaffected.
#'
#' The data are distributed under the Statistics Canada Open Licence
#' (<https://www.statcan.gc.ca/en/reference/licence>).
#'
#' @param path Path to one Area Master File. [canstreet_download()] delivers a
#'   vintage as a zip archive of them, to be extracted first.
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
#' files <- utils::unzip(amf$path[1], exdir = tempdir())
#' segs <- read_amf(grep("VANCOUVE", files, value = TRUE)[1])
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
