
.range_ops = list(
    '<' = "lt",
    '<=' = "lte",
    '>' = 'gt',
    '>=' = 'gte'
)

.regexp_ops = c('contains', 'startsWith', 'endsWith')

.range <- c('<', '<=', '>', '>=')

.match_ops = list(
    '==' = '='
)

.is_bool_connector <- function(x)
{
    if (length(x) == 0)
        return(FALSE)
    names <- names(x)
    names %in% c("filter", "should", "must_not") 
}

#' @importFrom jsonlite unbox
.binary_op <- function(sep)
{
    force(sep)
    function(e1, e2) {
        field <- as.character(substitute(e1))

        value <- try({
            e2
        }, silent = TRUE)
        if (inherits(value, "try-error")) {
            value <- as.character(substitute(e2))
            if(value[1] == 'c')
                value <- value[-1]
            value
        }

        fun <- "term"

        if(length(value) > 1)
            fun <- "terms"

        if(sep %in% .range)
            fun <- "range"

        if(sep %in% .regexp_ops) {
            fun <- 'regexp'
            ## TODO parse regex string to catch protected characters
            if(sep == 'contains')
                value <- paste0('.*', value, '.*')
            if(sep == 'startsWith')
                value <- paste0(value, '.*')
            if(sep == 'endsWith')
                value <- paste0('.*', value)
        }

        if (length(value) == 1L)
            value <- unbox(value)

        leaf <- list(value)
        if(fun == 'range') {
            names(leaf) <- .range[sep]
            leaf <- list(leaf)
        }
        names(leaf) <- field
        leaf <- list(leaf)
        names(leaf) <- fun

        if(sep == "!=")
            leaf <- list(must_not = leaf)

        leaf
    }
}

.not_op <- function(sep)
{
    force(sep)
    function(e1) {
        list(must_not = list(e1))
    }
}

.parenthesis_op <- function(sep)
{
    force(sep)
    function(e1) {
        if(.is_bool_connector(e1))
            list(bool = list(filter = list(list(bool = e1))))
        else
            list(bool = list(filter = list(e1)))
    }
}

.combine_op <- function(sep)
{
    force(sep)
    function(e1, e2) {
        fun <- "should"
        if (sep == '&')
            fun <- "filter"

        if(.is_bool_connector(e1))
            e1 <- list(bool = e1)
        if(.is_bool_connector(e2))
            e2 <- list(bool = e2)

        con <- list(list(e1, e2))
        names(con) <- fun
        con
    }
}

.get_selections <- function(x, ret_next = FALSE)
{
    if (ret_next)
        return(names(x))
    if(!is.null(names(x)) && names(x) %in% c("term", "terms", "range", "regexp"))
        lapply(x, .get_selections, TRUE)
    else
        lapply(x, .get_selections, FALSE)
}

#' @importFrom rlang eval_tidy f_rhs f_env
.hca_filter_loop <- function(li, expr)
{
    res <- rlang::eval_tidy(expr, data = .LOG_OP_REG)
    if(length(li) == 0) {
        if(.is_bool_connector(res))
            list(filter=list(list(bool = res)))
        else
            list(filter=list(res))
    }
    else {
        if (.is_bool_connector(li) & .is_bool_connector(res))
            list(filter = list(c(list(bool = li)), list(bool = res)))
        else if(.is_bool_connector(li))
            list(filter = list(c(list(bool = li)), res))
        else if(.is_bool_connector(res))
            list(filter = list(c(li, list(bool = res))))
        else
            list(filter = list(c(li, res)))
    }
}

.temp <- function(dots)
{
    res <- Reduce(.hca_filter_loop, dots, init =  list())
    list(es_query = list(query = list(bool = res)))
}

#' Filter HCABrowser objects
#'
#' @param .data an HCABrowser object to perform a query on.
#' @param .preserve unused.
#' @param ... further argument to be tranlated into a query to select from.
#'  These arguments can be passed in two ways, either as a single expression or
#'  as a series of expressions that are to be seperated by commas.
#'
#' @return a HCABrowser object containing the resulting query.
#'
#' @examples
#' hca <- HCABrowser()
#' hca2 <- hca %>% filter(organ.text == "brain")
#' hca2
#'
#' @export
#' @importFrom dplyr filter
#' @importFrom rlang quo_get_expr quos
filter.HCABrowser <- function(.data, ..., .preserve)
{
    hca <- .data
    dots <- quos(...)
    es_query <- c(hca@es_query, dots)
    hca@es_query <- es_query
    
    hca
}

#' Select fields from a HCABrowser object
#'
#' @param .data an HCABrowser object to perform a selection on
#' @param ... further argument to be tranlated into an expression to select from.
#'  These arguments can be passed in two ways, either as a character vector or
#'  as a series of expressions that are the fields that are to be selected
#'  seperated by commas.
#' @param .output_format unused.
#'
#' @return a HCABrowser object containing the results of the selection.
#'
#' @examples
#' hca <- HCABrowser()
#' hca2 <- hca %>% select('paired_end')
#' hca2
#'
#' hca3 <- hca %>% select(c('organ.text', 'paired_end'))
#' hca3
#' @export
#' @importFrom dplyr select
#' @importFrom rlang quo_get_expr
select.HCABrowser <- function(.data, ..., .output_format = c('raw', 'summary'))
{
    hca <- .data
    sources <- quos(...)
    output_format <- match.arg(.output_format)
    sources <- c(hca@es_source, sources)
    hca@es_source <- sources
    sources <- lapply(sources, function(x) {
        val <- try ({
            rlang::eval_tidy(x)
        }, silent = TRUE)
        if (inherits(val, "try-error")) {
            val <- as.character(rlang::quo_get_expr(x))
        }
        val
    })
    sources <- unlist(sources)
    if (length(sources) && sources[1] == 'c')
        sources <- sources[-1]

    search_term <- hca@search_term
    if(length(search_term) == 0)
        search_term <- list(es_query = list(query = NULL))
    search_term$es_query$"_source" <- sources
    hca@search_term <- search_term
    hca
}

.LOG_OP_REG <- list()
## Assign conditions.
.LOG_OP_REG$`==` <- .binary_op("==")
.LOG_OP_REG$`%in%` <- .binary_op("==")
.LOG_OP_REG$`!=` <- .binary_op("!=")
.LOG_OP_REG$`>` <- .binary_op(">")
.LOG_OP_REG$`<` <- .binary_op("<")
.LOG_OP_REG$`>=` <- .binary_op(">=")
.LOG_OP_REG$`<=` <- .binary_op("<=")
## Custom binary operators 
.LOG_OP_REG$`%startsWith%` <- .binary_op("startsWith")
.LOG_OP_REG$`%endsWith%` <- .binary_op("endsWith")
.LOG_OP_REG$`%contains%` <- .binary_op("contains")
## not conditional.
.LOG_OP_REG$`!` <- .not_op("!")
## parenthesis
.LOG_OP_REG$`(` <- .parenthesis_op("(")
## combine filters
.LOG_OP_REG$`&` <- .combine_op("&")
.LOG_OP_REG$`|` <- .combine_op("|")

`%startsWith%` <- function(e1, e2){}
`%endsWith%` <- function(e1, e2){}
`%contains%` <- function(e1, e2){}

