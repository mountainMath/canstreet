# Build and host the Area Master File archives.
#
# Statistics Canada does not serve the 1971 to 1986 Area Master Files online.
# The manifest (`R/sources.R`) reads them from one zip per census on
# MountainMath's S3 bucket, and this script is how those zips are made from the
# delivery and put there:
#
#   Rscript data-raw/amf_archives.R <delivery directory>             # build
#   Rscript data-raw/amf_archives.R <delivery directory> --upload    # and host
#
# The delivery directory is the one Statistics Canada sent: `AMF_1971`,
# `AMF_1976`, `AMF_1981`, `AMF_1986_Part1`, `AMF_1986_Part2` and
# `1996_1971_Documentation`. An archive holds a census's flat files untouched
# and under their own names at its top level, and a `documentation` directory
# with the documents that describe them and a `README.txt` saying what the
# archive is. `cs_resolve_amf_files()` ignores that directory.
#
# Archives land in `data-raw/amf_archives/`, which is not committed. One that
# is already there is kept rather than rebuilt (`--rebuild` to force it), so
# what is uploaded is what was tested. `--upload` needs the aws.s3 package and
# AWS credentials in the environment, refuses to overwrite an object that is
# already hosted unless `--replace` is given, and finishes by asking the
# package's own probe whether each URL now serves an archive.

args <- commandArgs(trailingOnly = TRUE)
flags <- args[startsWith(args, "--")]
delivery <- setdiff(args, flags)
if (length(delivery) != 1L || !dir.exists(delivery)) {
  stop("Usage: Rscript data-raw/amf_archives.R <delivery directory> ",
       "[--rebuild] [--upload] [--replace]", call. = FALSE)
}
delivery <- normalizePath(delivery)
out <- file.path("data-raw", "amf_archives")
dir.create(out, showWarnings = FALSE, recursive = TRUE)
out <- normalizePath(out)

bucket <- "mountainmath"
region <- "ca-central-1"
prefix <- "canstreet/"

guide <- "AMF_86_Users_Guide.pdf"
censuses <- list(
  `1971` = list(dirs = "AMF_1971",
                docs = c("AMF_71_76_81_record_layout.pdf",
                         "AMF_71_reference_list.pdf",
                         "AMF_71_number of records.pdf", guide)),
  `1976` = list(dirs = "AMF_1976",
                docs = c("AMF_71_76_81_record_layout.pdf",
                         "AMF_76_reference_list.pdf",
                         "AMF_76_number of records.pdf", guide)),
  `1981` = list(dirs = "AMF_1981",
                docs = c("AMF_71_76_81_record_layout.pdf",
                         "AMF_81_number of records.pdf", guide)),
  `1986` = list(dirs = c("AMF_1986_Part1", "AMF_1986_Part2"),
                docs = c("AMF_86_record_layout.pdf", guide)))

readme <- function(year, n_files, docs) {
  c(paste0("Area Master File, ", year, " Census of Canada -- Statistics ",
           "Canada, Geography Division"),
    "",
    paste0("This archive holds the ", year, " Area Master Files as ",
           "Statistics Canada delivered"),
    paste0("them: ", n_files, " flat files, one per municipality or small ",
           "group of municipalities,"),
    "under their original names, unmodified. Each file is fixed-width text, 119",
    "bytes to a record, describing streets and other features as chains of nodes",
    "in NAD27 UTM coordinates; the UTM zone is stated in the file's heading record.",
    "",
    "The files were never published online. Statistics Canada supplied them on",
    "request, with the documents in this directory, and they are redistributed here",
    "so that the canstreet R package (https://github.com/mountainMath/canstreet)",
    paste0("can read them: canstreet::get_road_network(", year, ") downloads ",
           "and imports this"),
    "archive, and canstreet::read_amf() reads a single file.",
    "",
    "Documents in this directory:",
    paste0("  ", docs),
    paste0(guide, " is The Area Master File User Guide (January 1988). It"),
    "describes the 1986 file; no guide to the earlier files is known to survive,",
    "and it is included with them because its lists are the nearest account of",
    "their feature codes. The record layouts describe the 95-byte EBCDIC record",
    "with packed coordinates, of which these text files are a transcription.",
    "",
    paste0("Source: Statistics Canada, Area Master File, ", year, ". Reproduced ",
           "and distributed on"),
    "an \"as is\" basis with the permission of Statistics Canada, under the",
    paste0("Statistics Canada Open Licence: ",
           "https://www.statcan.gc.ca/en/reference/licence"))
}

build <- function(year, spec, zipfile) {
  files <- list.files(file.path(delivery, spec$dirs), pattern = "[.]TXT$",
                      full.names = TRUE)
  docs <- file.path(delivery, "1996_1971_Documentation", spec$docs)
  stopifnot(length(files) > 0L, !anyDuplicated(basename(files)),
            all(file.exists(docs)))

  stage <- file.path(tempfile("amf_"), year)
  dir.create(file.path(stage, "documentation"), recursive = TRUE)
  stopifnot(all(file.copy(files, stage, copy.date = TRUE)),
            all(file.copy(docs, file.path(stage, "documentation"),
                          copy.date = TRUE)))
  writeLines(readme(year, length(files), spec$docs),
             file.path(stage, "documentation", "README.txt"))

  unlink(zipfile)
  owd <- setwd(stage)
  on.exit(setwd(owd), add = TRUE)
  members <- c(sort(basename(files)), "documentation")
  if (utils::zip(zipfile, members, flags = "-r9XqD") != 0L) {
    stop("zip failed for ", year, call. = FALSE)
  }

  # What went in is what the delivery holds, byte for byte.
  check <- tempfile("amf_check_")
  utils::unzip(zipfile, exdir = check)
  same <- tools::md5sum(file.path(check, basename(files))) ==
    tools::md5sum(files)
  stopifnot(all(same))
  unlink(c(dirname(stage), check), recursive = TRUE)
  invisible(zipfile)
}

archives <- file.path(out, paste0("amf_", names(censuses), ".zip"))
names(archives) <- names(censuses)
for (year in names(censuses)) {
  if (file.exists(archives[[year]]) && !"--rebuild" %in% flags) next
  message("Building ", basename(archives[[year]]))
  build(year, censuses[[year]], archives[[year]])
}

print(data.frame(
  archive = basename(archives),
  files = vapply(archives, function(z) {
    sum(!grepl("/", utils::unzip(z, list = TRUE)$Name))
  }, integer(1)),
  bytes = file.size(archives),
  sha256 = unname(tools::sha256sum(archives)),
  row.names = NULL))

if ("--upload" %in% flags) {
  for (year in names(archives)) {
    key <- paste0(prefix, basename(archives[[year]]))
    hosted <- suppressMessages(suppressWarnings(tryCatch(
      isTRUE(aws.s3::object_exists(key, bucket, region = region)),
      error = function(e) FALSE)))
    if (hosted && !"--replace" %in% flags) {
      message("s3://", bucket, "/", key, " is already hosted; left alone.")
      next
    }
    message("Uploading s3://", bucket, "/", key)
    ok <- aws.s3::put_object(
      file = archives[[year]], object = key, bucket = bucket, region = region,
      multipart = TRUE, acl = "public-read",
      headers = list("Content-Type" = "application/zip"))
    if (!isTRUE(ok)) stop("Upload failed for ", key, call. = FALSE)
  }

  pkgload::load_all(quiet = TRUE)
  urls <- vapply(as.integer(names(archives)), cs_amf_url, character(1))
  served <- vapply(urls, cs_url_is_available, logical(1))
  print(data.frame(url = urls, served = served, row.names = NULL))
  if (!all(served)) stop("Not every archive is being served.", call. = FALSE)
}
