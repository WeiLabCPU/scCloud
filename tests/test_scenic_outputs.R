# Run from the repository root: Rscript tests/test_scenic_outputs.R
# Exercise the actual /scenic route with a lightweight stand-in for GENIE3/AUCell.
plumber_expr <- parse(file = "r-engine/plumber.R")
scenic_expr <- parse(file = "r-engine/R/scenic.R")
eval(scenic_expr)
stopifnot(inherits(try(RunScenic(NULL, tempdir(), maxCells = 0), silent = TRUE), "try-error"))
stopifnot(inherits(try(RunScenic(NULL, tempdir(), nCores = 0), silent = TRUE), "try-error"))

for (expr in plumber_expr) {
  if (is.call(expr) && identical(expr[[1]], as.name("<-")) &&
      identical(expr[[2]], as.name("make_output_name"))) eval(expr)
}
route_expr <- Filter(function(expr) {
  is.call(expr) && identical(expr[[1]], as.name("function")) &&
    any(grepl("RunScenic", deparse(expr), fixed = TRUE))
}, as.list(plumber_expr))
stopifnot(length(route_expr) == 1L)
route <- eval(route_expr[[1]])
`%||%` <- function(x, y) if (is.null(x)) y else x
create_progress_reporter <- function(...) function(...) invisible(NULL)
open_plot_device <- function(path, ...) grDevices::pdf(path)

project <- tempfile("scenic-project-")
dir.create(project)
on.exit_cleanup <- function() unlink(project, recursive = TRUE)
saveRDS(list(), file.path(project, "seurat_annotated.rds"))
RunScenic <- function(pro, outdir, ref, nCores, maxCells, plot_format, ...) {
  stopifnot(maxCells == 1234, plot_format == "pdf")
  output <- function(name) {
    path <- file.path(outdir, name)
    writeLines("result", path)
    path
  }
  list(plot = 1, stat_plot = 2,
       heatmap_path = output("auc.pdf"), bin_heatmap_path = output("binary.pdf"),
       table_path = output("regulons.csv"), auc_matrix_path = output("auc.csv"),
       bin_matrix_path = output("binary.csv"), n_regulons = 2, n_cells = 2000,
       n_cells_sub = 1234, regulons = c("TF1", "TF2"))
}
result <- route(list(postBody = jsonlite::toJSON(list(
  project_path = project, params = list(max_cells = 1234, plot_format = "pdf")
), auto_unbox = TRUE)))
paths <- unlist(c(result$plot_paths, result$data_paths))
stopifnot(length(paths) == 7L, all(file.exists(paths)),
          all(dirname(paths) == project), all(grepl("_scenic_", basename(paths))),
          all(endsWith(unlist(result$plot_paths), ".pdf")),
          result$stats$n_cells_sub == 1234)
on.exit_cleanup()
cat("SCENIC parameter validation and output archive checks passed\n")
