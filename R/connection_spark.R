

#' @import sparkapi
NULL

# register the spark_connection S3 class for use in setClass slots
methods::setOldClass("spark_connection")
methods::setOldClass("spark_jobj")

spark_version_numeric <- function(version) {
  gsub("[-_a-zA-Z]", "", version)
}

spark_default_jars <- function(version) {
  sparkJarPathFromVersion <- function(version) {
    system.file(
      file.path("java",
              paste0("sparklyr-",
                     spark_version_numeric(version),
                     ".jar")
      ),
      package = "sparklyr")
  }

  if (is.null(version) ||
      !file.exists(sparkJarPathFromVersion(version))) {
    # use version 1.6.1 as the default
    version <- "1.6.1"
  }

  jarsOption <- getOption(
    "spark.jars.default",
    sparkJarPathFromVersion(version)
  )
}

#' Connect to Spark
#'
#' @param master Spark cluster url to connect to. Use \code{"local"} to connect to a local
#'   instance of Spark installed via \code{\link{spark_install}}.
#' @param spark_home Spark home directory (defaults to SPARK_HOME environment variable).
#'   If \code{SPARK_HOME} is defined it will be always be used unless the \code{version}
#'   paramater is specified to force the use of a locally installed version.
#' @param app_name Application name to be used while running in the Spark cluster
#' @param version Version of Spark (only applicable for local master)
#' @param hadoop_version Version of Hadoop (only applicable for local master)
#' @param extensions Extension packages to enable for this connection. By default will
#'   enable all packages that previously called \code{sparkapi::register_extension}.
#' @param config Configuration for connection (see \code{\link{spark_config} for details}).
#'
#' @return Connection to Spark local instance or remote cluster
#'
#' @family Spark connections
#'
#' @export
spark_connect <- function(master,
                          spark_home = Sys.getenv("SPARK_HOME"),
                          app_name = "sparklyr",
                          version = NULL,
                          hadoop_version = NULL,
                          config = spark_config(),
                          extensions = sparkapi::registered_extensions()) {

  # for local mode we support SPARK_HOME via locally installed versions
  if (spark_master_is_local(master)) {
    if (!nzchar(spark_home) && (!is.null(version) || !is.null(hadoop_version))) {
      installInfo <- spark_install_find(version, hadoop_version, latest = FALSE, connecting = TRUE)
      spark_home <- installInfo$sparkVersionDir
    }
  }

  # prepare windows environment
  prepare_windows_environment(spark_home)

  # master can be missing if it's specified in the config file
  if (missing(master)) {
    master <- config$spark.master
    if (is.null(master))
      stop("You must either pass a value for master or include a spark.master ",
           "entry in your config.yml")
  }

  # determine whether we need cores in master
  passedMaster <- master
  cores <- config[["sparklyr.cores.local"]]
  if (master == "local" && !identical(cores, NULL))
    master <- paste("local[", cores, "]", sep = "")

  filter <- function(e) {
    connection_is_open(e) &&
    identical(e$master, master) &&
    identical(e$app_name, app_name)
  }

  sconFound <- spark_connection_find_scon(filter)
  if (length(sconFound) == 1) {
    message("Re-using existing Spark connection to ", passedMaster)
    return(sconFound[[1]])
  }

  # verify that java is available
  if (!is_java_available()) {
    stop("Java is required to connect to Spark. Please download and install Java from ",
         java_install_url())
  }

  # error if there is no SPARK_HOME
  if (!nzchar(spark_home))
    stop("Failed to connect to Spark (SPARK_HOME is not set).")

  scon <- NULL
  tryCatch({

    # determine environment
    environment <- list()
    if (spark_master_is_local(master))
      environment$SPARK_LOCAL_IP = "127.0.0.1"

    # determine shell_args (use fake connection b/c we don't yet
    # have a real connection)
    config_sc <- list(config = config, master = master)
    shell_args <- connection_config(config_sc, "sparklyr.shell.")

    # flatten shell_args to make them compatible with sparkapi
    shell_args <- unlist(lapply(names(shell_args), function(name) {
      list(paste0("--", name), shell_args[[name]])
    }))

    versionSparkHome <- sparkapi::spark_version_from_home(spark_home, default = version)

    # start shell
    scon <- sparkapi::start_shell(
      master = master,
      spark_home = spark_home,
      spark_version = version,
      app_name = app_name,
      config = config,
      jars = spark_default_jars(versionSparkHome),
      packages = config[["sparklyr.defaultPackages"]],
      extensions = extensions,
      environment = environment,
      shell_args = shell_args
    )

    # mark the connection as a DBIConnection class to allow DBI to use defaults
    attr(scon, "class") <- c(attr(scon, "class"), "DBIConnection")

    # update spark_context and hive_context connections with DBIConnection
    scon$spark_context$connection <- scon
    scon$hive_context$connection <- scon

    # notify connection viewer of connection
    libs <- c("sparklyr", extensions)
    libs <- vapply(libs,
                   function(lib) paste0("library(", lib, ")"),
                   character("1"),
                   USE.NAMES = FALSE)
    libs <- paste(libs, collapse = "\n")
    if ("package:dplyr" %in% search())
      libs <- paste(libs, "library(dplyr)", sep = "\n")
    parentCall <- match.call()
    connectCall <- paste(libs,
                         paste("sc <-", deparse(parentCall, width.cutoff = 500), collapse = " "),
                         sep = "\n")
    on_connection_opened(scon, connectCall)

    # Register a finalizer to sleep on R exit to support older versions of the RStudio ide
    reg.finalizer(as.environment("package:sparklyr"), function(x) {
      if (connection_is_open(scon)) {
        Sys.sleep(1)
      }
    }, onexit = TRUE)
  }, error = function(err) {
    tryCatch({
      spark_log(scon)
    }, error = function(e) {
    })
    stop(err)
  })

  # add to our internal list
  spark_connections_add(scon)

  # return scon
  scon
}

#' @docType NULL
#' @name spark_log
#' @rdname spark_log
#'
#' @export
sparkapi::spark_log

#' @export
spark_log.spark_connection <- function(sc, n = 100, ...) {
  if (.Platform$OS.type == "windows") {
    log <- file("log4j.spark.log")
    lines <- readr::read_lines(log)

    tryCatch(function() {
      close(log)
    })

    if (!is.null(n))
      linesLog <- utils::tail(lines, n = n)
    else
      linesLog <- lines
    attr(linesLog, "class") <- "sparklyr_log"

    linesLog
  }
  else {
    class(sc) <- "spark_shell_connection"
    sparkapi::spark_log(sc, n, ...)
  }
}

#' @export
print.sparklyr_log <- function(x, ...) {
  cat(x, sep = "\n")
  cat("\n")
}

#' @docType NULL
#' @name spark_web
#' @rdname spark_web
#'
#' @export
sparkapi::spark_web


#' Check if a Spark connection is open
#'
#' @param sc \code{spark_connection}
#'
#' @rdname spark_connection_is_open
#'
#' @keywords internal
#'
#' @export
spark_connection_is_open <- function(sc) {
  sparkapi::connection_is_open(sc)
}

#' Disconnect from Spark
#'
#' @param x A \code{\link{spark_connect}} connection or the Spark master
#' @param ... Additional arguments
#'
#' @family Spark connections
#'
#' @export
spark_disconnect <- function(x, ...) {
  UseMethod("spark_disconnect")
}

#' @export
spark_disconnect.spark_connection <- function(x, ...) {
  tryCatch({
    sparkapi::stop_shell(x)
  }, error = function(err) {
  })

  spark_connections_remove(x)

  on_connection_closed(x)
}

#' @export
spark_disconnect.character <- function(x, ...) {
  args <- list(...)
  master <- if (!is.null(args$master)) args$master else x
  app_name <- args$app_name

  connections <- spark_connection_find_scon(function(e) {
    e$master <- gsub("\\[\\d*\\]", "", e$master)

    e$master == master &&
      (is.null(app_name) || e$app_name == app_name)
  })

  length(lapply(connections, function(sc) {
    spark_disconnect(sc)
  }))
}

# get the spark_web url (used by IDE)
spark_web <- function(sc) {
  sparkapi::spark_web(sc)
}


# Get the path to a temp file containing the current spark log (used by IDE)
spark_log_file <- function(sc) {
  scon <- sc
  if (!connection_is_open(scon)) {
    stop("The Spark conneciton is not open anymmore, log is not available")
  }

  lines <- spark_log(sc, n = NULL)
  tempLog <- tempfile(pattern = "spark", fileext = ".log")
  writeLines(lines, tempLog)

  tempLog
}

# TRUE if the Spark Connection is a local install
spark_connection_is_local <- function(sc) {
  spark_master_is_local(sc$master)
}

spark_master_is_local <- function(master) {
  grepl("^local(\\[[0-9\\*]*\\])?$", master, perl = TRUE)
}

# Number of cores available in the local install
spark_connection_local_cores <- function(sc) {
  sc$config[["sparklyr.cores"]]
}

#' Close all existing connections
#'
#' @family Spark connections
#'
#' @rdname spark_disconnect
#' @export
spark_disconnect_all <- function() {
  scons <- spark_connection_find_scon(function(e) {
    connection_is_open(e)
  })

  length(lapply(scons, function(e) {
    spark_disconnect(e)
  }))
}

spark_inspect <- function(jobj) {
  print(jobj)
  if (!connection_is_open(spark_connection(jobj)))
    return(jobj)

  class <- invoke(jobj, "getClass")

  cat("Fields:\n")
  fields <- invoke(class, "getDeclaredFields")
  lapply(fields, function(field) { print(field) })

  cat("Methods:\n")
  methods <- invoke(class, "getDeclaredMethods")
  lapply(methods, function(method) { print(method) })

  jobj
}

