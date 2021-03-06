#' Combine p-values
#'
#' Combine p-values from independent or dependent hypothesis tests using a variety of meta-analysis methods.
#' 
#' @param ... Two or more numeric vectors of p-values of the same length.
#' @param method A string specifying the combining strategy to use.
#' @param weights A numeric vector of positive weights, with one value per vector in \code{...}.
#' Alternatively, a list of numeric vectors of weights, with one vector per element in \code{...}.
#' This is only used when \code{method="z"}.
#' @param log.p Logical scalar indicating whether the p-values in \code{...} are log-transformed.
#' @param min.prop Numeric scalar in [0, 1] specifying the minimum proportion of tests to reject for each set of p-values when \code{method="holm-middle"}.
#' 
#' @details
#' This function will operate across elements on \code{...} in parallel to combine p-values.
#' That is, the set of first p-values from all vectors will be combined, followed by the second p-values and so on.
#' This is useful for combining p-values for each gene across different hypothesis tests.
#' 
#' Fisher's method, Stouffer's Z method and Simes' method test the global null hypothesis that all of the individual null hypotheses in the set are true.
#' The global null is rejected if any of the individual nulls are rejected.
#' However, each test has different characteristics:
#' \itemize{
#' \item Fisher's method requires independence of the test statistic.
#' It is useful in asymmetric scenarios, i.e., when the null is only rejected in one of the tests in the set.
#' Thus, a low p-value in any test is sufficient to obtain a low combined p-value.
#' \item Stouffer's Z method require independence of the test statistic.
#' It favours symmetric rejection and is less sensitive to a single low p-value, requiring more consistently low p-values to yield a low combined p-value.
#' It can also accommodate weighting of the different p-values.
#' \item Simes' method technically requires independence but tends to be quite robust to dependencies between tests.
#' See Sarkar and Chung (1997) for details, as well as work on the related Benjamini-Hochberg method.
#' It favours asymmetric rejection and is less powerful than the other two methods under independence.
#' }
#' 
#' Berger's intersection-union test examines a different global null hypothesis -
#' that at least one of the individual null hypotheses are true.
#' Rejection in the IUT indicates that all of the individual nulls have been rejected.
#' This is the statistically rigorous equivalent of a naive intersection operation.
#'
#' In the Holm-middle approach, the global null hypothesis is that more than \code{1 - min.prop} proportion of the individual nulls in the set are true.
#' We apply the Holm-Bonferroni correction to all p-values in the set and take the \code{ceiling(min.prop * N)}-th smallest value where \code{N} is the size of the set (excluding \code{NA} values).
#' This method works correctly in the presence of correlations between p-values.
#'
#' % We apply Holm until we reject the ceil(N * min.prop)-th test, which causes us to reject the global null.
#' % The combined p-value is thus defined as the p-value at this rejection point.
#' 
#' @return 
#' A numeric vector containing the combined p-values.
#' 
#' @author
#' Aaron Lun
#' 
#' @references
#' Fisher, R.A. (1925).
#' \emph{Statistical Methods for Research Workers.}
#' Oliver and Boyd (Edinburgh).
#' 
#' Whitlock MC (2005).
#' Combining probability from independent tests: the weighted Z-method is superior to Fisher's approach.
#' \emph{J. Evol. Biol.} 18, 5:1368-73.
#' 
#' Simes RJ (1986).
#' An improved Bonferroni procedure for multiple tests of significance.
#' \emph{Biometrika} 73:751-754.
#' 
#' Berger RL and Hsu JC (1996).
#' Bioequivalence trials, intersection-union tests and equivalence confidence sets.
#' \emph{Statist. Sci.} 11, 283-319.
#' 
#' Sarkar SK and Chung CK (1997).
#' The Simes method for multiple hypothesis testing with positively dependent test statistics.
#' \emph{J. Am. Stat. Assoc.} 92, 1601-1608.
#' 
#' @examples
#' p1 <- runif(10000)
#' p2 <- runif(10000)
#' p3 <- runif(10000)
#' 
#' fish <- combinePValues(p1, p2, p3)
#' hist(fish)
#' 
#' z <- combinePValues(p1, p2, p3, method="z", weights=1:3)
#' hist(z)
#' 
#' simes <- combinePValues(p1, p2, p3, method="simes")
#' hist(simes)
#' 
#' berger <- combinePValues(p1, p2, p3, method="berger")
#' hist(berger)
#'
#' @export
#' @importFrom stats pnorm qnorm pchisq
#' @importFrom DelayedMatrixStats rowRanks rowQuantiles 
#' @importFrom DelayedArray rowMins
combinePValues <- function(..., 
    method=c("fisher", "z", "simes", "berger", "holm-middle"), 
    weights=NULL, log.p=FALSE, min.prop=0.5)
{
    input <- list(...)
    if (length(input)==1L) {
        return(unname(input[[1]])) # returning directly.
    }
    Np <- unique(lengths(input))
    if (length(Np) != 1) {
        stop("all p-value vectors must have the same length")
    }

    method <- match.arg(method)
    switch(method,
        fisher={
            if (log.p) {
                all.logp <- input
            } else {
                all.logp <- lapply(input, FUN=log)
            }

            n <- integer(Np)
            X <- numeric(Np)
            for (i in seq_along(all.logp)) {
                current <- all.logp[[i]]
                keep <- !is.na(current)
                X[keep] <- X[keep] + current[keep]
                n <- n + keep
            }
            
            n[n==0] <- NA_real_ # ensure that we get NA outputs.
            pchisq(-2*X, df=2*n, lower.tail=FALSE, log.p=log.p)
        },
        simes=combine_simes(input, log.p),
        `holm-middle`=combine_holm_middle(input, log.p, min.prop),
        z={
            if (is.null(weights)) {
                weights <- rep(1, length(input))
            } else if (length(weights)!=length(input)) {
                stop("'length(weights)' must be equal to number of vectors in '...'")
            } else {
                check <- unlist(lapply(weights, range))
                if (any(is.na(check) | check<=0)) {
                    stop("weights must be positive")
                }
            }

            Z <- W2 <- numeric(Np)
            for (i in seq_along(input)) {
                current <- input[[i]]
                keep <- !is.na(current)
                Z[keep] <- Z[keep] + qnorm(current[keep], log.p=log.p) * weights[[i]]
                W2 <- W2 + ifelse(keep, weights[[i]]^2, 0)
            }

            # Combining p-values of 0 and 1 will yield zscores of -Inf + Inf => NaN.
            # Here, we set them to 0 to get p-values of 0.5, as the Z-method doesn't
            # give coherent answers when you have p-values at contradicting extremes.
            Z[is.nan(Z)] <- 0

            W2[W2==0] <- NA_real_ # ensure we get NA outputs.
            pnorm(Z/sqrt(W2), log.p=log.p) 
        },
        berger={
            do.call(pmax, c(input, list(na.rm=TRUE)))
        }
    )
}
