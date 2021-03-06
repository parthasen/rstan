# This file is part of RStan
# Copyright (C) 2012, 2013, 2014, 2015 Jiqiang Guo and Benjamin Goodrich
#
# RStan is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 3
# of the License, or (at your option) any later version.
#
# RStan is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

setMethod("show", "stanmodel",
          function(object) {
            cat("S4 class stanmodel '", object@model_name, "' coded as follows:\n" ,sep = '') 
            cat(object@model_code, "\n")
          }) 

setGeneric(name = 'optimizing',
           def = function(object, ...) { standardGeneric("optimizing")})

setGeneric(name = "sampling",
           def = function(object, ...) { standardGeneric("sampling")})

setGeneric(name = "get_cppcode", 
           def = function(object, ...) { standardGeneric("get_cppcode") })

setMethod("get_cppcode", "stanmodel", 
          function(object) {
            object@model_cpp$model_cppcode  
          }) 

setGeneric(name = "get_cxxflags", 
           def = function(object, ...) { standardGeneric("get_cxxflags") })
setMethod("get_cxxflags", "stanmodel", function(object) { object@dso@cxxflags }) 

new_empty_stanfit <- function(stanmodel, miscenv = new.env(parent = emptyenv()), 
                              model_pars = character(0), par_dims = list(), 
                              mode = 2L, sim = list(), 
                              inits = list(), stan_args = list()) { 
  new("stanfit",
      model_name = stanmodel@model_name,
      model_pars = model_pars, 
      par_dims = par_dims, 
      mode = mode,
      sim = sim, 
      inits = inits, 
      stan_args = stan_args, 
      stanmodel = stanmodel, 
      date = date(),
      .MISC = miscenv) 
} 

prep_call_sampler <- function(object) {
  if (!is_sm_valid(object))
    stop(paste("the compiled object from C++ code for this model is invalid, possible reasons:\n",
               "  - compiled with save_dso=FALSE;\n", 
               "  - compiled on a different platform;\n", 
               "  - not existed (created from reading csv files).", sep = '')) 
  if (!is_dso_loaded(object@dso)) {
    # load the dso if available 
    grab_cxxfun(object@dso) 
  } 
} 

setMethod("optimizing", "stanmodel", 
          function(object, data = list(), 
                   seed = sample.int(.Machine$integer.max, 1),
                   init = 'random', check_data = TRUE, sample_file = NULL, 
                   algorithm = c("LBFGS", "BFGS", "Newton"),
                   verbose = FALSE, hessian = FALSE, as_vector = TRUE, ...) {
            prep_call_sampler(object)
            model_cppname <- object@model_cpp$model_cppname 
            mod <- get("module", envir = object@dso@.CXXDSOMISC, inherits = FALSE) 
            stan_fit_cpp_module <- eval(call("$", mod, paste('stan_fit4', model_cppname, sep = ''))) 
            if (check_data) {
              if (is.character(data)) {
                data <- try(mklist(data))
                if (is(data, "try-error")) {
                  message("failed to create the data; optimization not done") 
                  return(invisible(NULL))
                }
              }
              if (!missing(data) && length(data) > 0) {
                data <- try(data_preprocess(data))
                if (is(data, "try-error")) {
                  message("failed to preprocess the data; optimization not done") 
                  return(invisible(list(stanmodel = object)))
                }
              } else data <- list()
            } 
            sampler <- try(new(stan_fit_cpp_module, data, object@dso@.CXXDSOMISC$cxxfun)) 
            if (is(sampler, "try-error")) {
              message('failed to create the optimizer; optimization not done') 
              return(invisible(list(stanmodel = object)))
            } 
            m_pars <- sampler$param_names() 
            idx_wo_lp <- which(m_pars != "lp__")
            m_pars <- m_pars[idx_wo_lp]
            p_dims <- sampler$param_dims()[idx_wo_lp]
            if (is.numeric(init)) init <- as.character(init)
            if (is.function(init)) init <- init()
            if (!is.list(init) && !is.character(init)) {
              message("wrong specification of initial values")
              return(invisible(list(stanmodel = object)))
            } 
            seed <- check_seed(seed, warn = 1)    
            if (is.null(seed))
              return(invisible(list(stanmodel = object)))
            args <- list(init = init, 
                         seed = seed, 
                         method = "optim", 
                         algorithm = match.arg(algorithm)) 
         
            if (!is.null(sample_file) && !is.na(sample_file)) 
              args$sample_file <- writable_sample_file(sample_file) 
            dotlist <- list(...)
            is_arg_recognizable(names(dotlist), 
                                c("iter",
                                  "save_iterations",
                                  "refresh",
                                  "init_alpha",
                                  "tol_obj",
                                  "tol_grad",
                                  "tol_param",
                                  "tol_rel_obj",
                                  "tol_rel_grad",
                                  "history_size"),
                                 pre_msg = "passing unknown arguments: ",
                                 call. = FALSE)
            if (!is.null(dotlist$method))  dotlist$method <- NULL
            optim <- sampler$call_sampler(c(args, dotlist))
            names(optim$par) <- flatnames(m_pars, p_dims, col_major = TRUE)
            skeleton <- create_skeleton(m_pars, p_dims)
            if(hessian) {
              fn <- function(theta) {
                sampler$log_prob(theta, FALSE, FALSE)
              }
              gr <- function(theta) {
                sampler$grad_log_prob(theta, FALSE)
              }
              theta <- rstan_relist(optim$par, skeleton)
              theta <- sampler$unconstrain_pars(theta)
              optim$hessian <- optimHess(theta, fn, gr,
                                         control = list(fnscale = -1))
              colnames(optim$hessian) <- rownames(optim$hessian) <- 
                sampler$unconstrained_param_names(FALSE, FALSE)
            }
            if (!as_vector) optim$par <- rstan_relist(optim$par, skeleton)
            return(optim)
          }) 

setMethod("sampling", "stanmodel",
          function(object, data = list(), pars = NA, chains = 4, iter = 2000,
                   warmup = floor(iter / 2),
                   thin = 1, seed = sample.int(.Machine$integer.max, 1),
                   init = "random", check_data = TRUE, 
                   sample_file = NULL, diagnostic_file = NULL, verbose = FALSE, 
                   algorithm = c("NUTS", "HMC", "Fixed_param"), #, "Metropolis"), 
                   control = NULL, cores = getOption("mc.cores", 1L), 
                   open_progress = interactive() && !isatty(stdout()), ...) {

            # allow data to be specified as a vector of character string
            if (is.character(data)) {
              data <- try(mklist(data))
              if (is(data, "try-error")) {
                message("failed to create the data; sampling not done")
                return(invisible(new_empty_stanfit(object)))
              }
            }
            # check data and preprocess
            if (check_data) {
              data <- try(force(data))
              if (is(data, "try-error")) {
                message("failed to evaluate the data; sampling not done")
                return(invisible(new_empty_stanfit(object)))
              }
              if (!missing(data) && length(data) > 0) {
                data <- try(data_preprocess(data))
                if (is(data, "try-error")) {
                  message("failed to preprocess the data; sampling not done")
                  return(invisible(new_empty_stanfit(object)))
                }
              } else data <- list()
            }

            if (chains > 1 && cores > 1) {
              dotlist <- c(sapply(ls(), simplify = FALSE, FUN = get,
                                  envir = environment()), list(...))
              dotlist$chains <- 1L
              dotlist$cores <- 1L
              dotlist$data <- data
              if(open_progress && 
                 !identical(browser <- getOption("browser"), "false")) {
                sinkfile <- paste0(tempfile(), "_StanProgress.txt")
                cat("Refresh to see progress\n", file = sinkfile)
                if(.Platform$OS.type == "windows" && is.null(browser)) {
                  browser <- file.path(Sys.getenv("ProgramFiles(x86)"), 
                                       "Internet Explorer", "iexplore.exe")
                  if(!file.exists(browser)) {
                    browser <- file.path(Sys.getenv("ProgramFiles"), 
                                         "Internet Explorer", "iexplore.exe")
                    if(!file.exists(browser)) {
                      warning("Cannot find Internet Explorer; consider setting 'options(browser = )' explicitly")
                      browser <- NULL
                    }
                  }
                }
                else if(Sys.info()["sysname"] == "Darwin" && grepl("open$", browser)) {
                  browser <- "/Applications/Safari.app/Contents/MacOS/Safari"
                  if(!file.exists(browser)) {
                    warning("Cannot find Safari; consider setting 'options(browser = )' explicitly")
                    browser <- "/usr/bin/open"
                  }
                }
                utils::browseURL(sinkfile, browser = browser)
              }
              else sinkfile <- ""
              cl <- parallel::makeCluster(cores, outfile = sinkfile, useXDR = FALSE)
              on.exit(parallel::stopCluster(cl))
              parallel::clusterEvalQ(cl, expr = require(Rcpp, quietly = TRUE))
              callFun <- function(i) {
                dotlist$chain_id <- i
                if(is.list(dotlist$init)) dotlist$init <- dotlist$init[i]
                if(is.character(dotlist$sample_file)) {
                  dotlist$sample_file <- paste0(dotlist$sample_file, i)
                }
                if(is.character(dotlist$diagnostic_file)) {
                  dotlist$diagnostic_file <- paste0(dotlist$diagnostic_file, i)
                }
                Sys.sleep(0.5 * i)
                do.call(rstan::sampling, args = dotlist)
              }
              parallel::clusterExport(cl, varlist = "dotlist", envir = environment())
              nfits <- parallel::parLapply(cl, X = 1:chains, fun = callFun)
              if(all(sapply(nfits, is, class2 = "stanfit")) &&
                 all(sapply(nfits, FUN = function(x) x@mode == 0))) {
                 return(sflist2stanfit(nfits))
              }
              return(nfits[[1]])
            }
            dots <- list(...)
            check_unknown_args <- dots$check_unknown_args
            if (is.null(check_unknown_args) || check_unknown_args) {
              is_arg_recognizable(names(dots),
                                  c("chain_id", "init_r", "test_grad",
                                    "obfuscate_model_name",
                                    "enable_random_init",
                                    "append_samples", "refresh", "control", 
                                    "cores", "open_progress"), 
                                  pre_msg = "passing unknown arguments: ",
                                  call. = FALSE)
            }
            prep_call_sampler(object)
            model_cppname <- object@model_cpp$model_cppname 
            mod <- get("module", envir = object@dso@.CXXDSOMISC, inherits = FALSE) 
            stan_fit_cpp_module <- eval(call("$", mod, paste('stan_fit4', model_cppname, sep = ''))) 
            sampler <- try(new(stan_fit_cpp_module, data, object@dso@.CXXDSOMISC$cxxfun)) 
            sfmiscenv <- new.env(parent = emptyenv())
            if (is(sampler, "try-error")) {
              message('failed to create the sampler; sampling not done') 
              return(invisible(new_empty_stanfit(object, miscenv = sfmiscenv)))
            } 
            assign("stan_fit_instance", sampler, envir = sfmiscenv)
            # on.exit({rm(sampler); invisible(gc())}) 

            m_pars = sampler$param_names() 
            p_dims = sampler$param_dims() 
            if (!missing(pars) && !is.na(pars) && length(pars) > 0) {
              sampler$update_param_oi(pars)
              m <- which(match(pars, m_pars, nomatch = 0) == 0)
              if (length(m) > 0) {
                message("no parameter ", paste(pars[m], collapse = ', '), "; sampling not done") 
                return(invisible(new_empty_stanfit(object, miscenv = sfmiscenv, m_pars, p_dims, 2L))) 
              }
            }

            if (chains < 1) {
              message("the number of chains is less than 1; sampling not done") 
              return(invisible(new_empty_stanfit(object, miscenv = sfmiscenv, m_pars, p_dims, 2L))) 
            }

            args_list <- try(config_argss(chains = chains, iter = iter,
                                          warmup = warmup, thin = thin,
                                          init = init, seed = seed, sample_file = sample_file, 
                                          diagnostic_file = diagnostic_file, 
                                          algorithm = match.arg(algorithm), control = control, ...))
   
            if (is(args_list, "try-error")) {
              message('error in specifying arguments; sampling not done') 
              return(invisible(new_empty_stanfit(object, miscenv = sfmiscenv, m_pars, p_dims, 2L))) 
            }

            # number of samples saved after thinning
            warmup2 <- 1 + (warmup - 1) %/% thin 
            n_kept <- 1 + (iter - warmup - 1) %/% thin
            n_save <- n_kept + warmup2 

            samples <- vector("list", chains)
            mode <- if (!is.null(dots$test_grad) && dots$test_grad) "TESTING GRADIENT" else "SAMPLING"

            for (i in 1:chains) {
              if (is.null(dots$refresh) || dots$refresh > 0) 
                cat('\n', mode, " FOR MODEL '", object@model_name, 
                    "' NOW (CHAIN ", args_list[[i]]$chain_id, ").\n", sep = '')
              samples_i <- try(sampler$call_sampler(args_list[[i]])) 
              if (is(samples_i, "try-error") || is.null(samples_i)) {
                message("error occurred during calling the sampler; sampling not done") 
                return(invisible(new_empty_stanfit(object, miscenv = sfmiscenv,
                                                   m_pars, p_dims, 2L))) 
              }
              samples[[i]] <- samples_i
            }

            idx_wo_lp <- which(m_pars != 'lp__')
            skeleton <- create_skeleton(m_pars[idx_wo_lp], p_dims[idx_wo_lp])
            inits_used = lapply(lapply(samples, function(x) attr(x, "inits")), 
                                function(y) rstan_relist(y, skeleton))

            # test_gradient mode: no sample 
            if (attr(samples[[1]], 'test_grad')) {
              sim = list(num_failed = sapply(samples, function(x) x$num_failed))
              return(invisible(new_empty_stanfit(object, miscenv = sfmiscenv,
                                                 m_pars, p_dims, 1L, sim = sim, 
                                                 inits = inits_used, 
                                                 stan_args = args_list)))
            } 

            # perm_lst <- lapply(1:chains, function(id) rstan_seq_perm(n_kept, chains, seed, chain_id = id)) 
            ## sample_int is a little bit faster than our own rstan_seq_perm (one 
            ## reason is that the RNG used in R is faster),
            ## but without controlling the seed 
            perm_lst <- lapply(1:chains, function(id) sample.int(n_kept))

            fnames_oi <- sampler$param_fnames_oi()
            n_flatnames <- length(fnames_oi)
            sim = list(samples = samples,
                       iter = iter, thin = thin, 
                       warmup = warmup, 
                       chains = chains,
                       n_save = rep(n_save, chains),
                       warmup2 = rep(warmup2, chains), # number of warmpu iters in n_save
                       permutation = perm_lst,
                       pars_oi = sampler$param_names_oi(),
                       dims_oi = sampler$param_dims_oi(),
                       fnames_oi = fnames_oi,
                       n_flatnames = n_flatnames) 
            nfit <- new("stanfit",
                        model_name = object@model_name,
                        model_pars = m_pars, 
                        par_dims = p_dims, 
                        mode = 0L, 
                        sim = sim,
                        # keep a record of the initial values 
                        inits = inits_used, 
                        stan_args = args_list,
                        stanmodel = object, 
                          # keep a ref to avoid garbage collection
                          # (see comments in fun stan_model)
                        date = date(),
                        .MISC = sfmiscenv) 
             return(nfit)
          }) 

