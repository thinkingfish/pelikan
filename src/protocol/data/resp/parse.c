#include "parse.h"

#include "request.h"
#include "response.h"
#include "token.h"

#include <cc_array.h>
#include <cc_debug.h>
#include <cc_print.h>
#include <cc_util.h>

#include <ctype.h>

#define PARSE_MODULE_NAME "protocol::resp::parse"

static bool parse_init = false;
static parse_req_metrics_st *parse_req_metrics = NULL;
static parse_rsp_metrics_st *parse_rsp_metrics = NULL;

void
parse_setup(parse_req_metrics_st *req, parse_rsp_metrics_st *rsp)
{
    log_info("set up the %s module", PARSE_MODULE_NAME);

    if (parse_init) {
        log_warn("%s has already been setup, overwrite", PARSE_MODULE_NAME);
    }

    parse_req_metrics = req;
    parse_rsp_metrics = rsp;
    parse_init = true;
}

void
parse_teardown(void)
{
    log_info("tear down the %s module", PARSE_MODULE_NAME);

    if (!parse_init) {
        log_warn("%s has never been setup", PARSE_MODULE_NAME);
    }

    parse_req_metrics = NULL;
    parse_rsp_metrics = NULL;
    parse_init = false;
}

static parse_rstatus_e
_parse_cmd(struct request *req)
{
    cmd_type_e type;
    struct command cmd;
    struct element *el;
    int narg;

    ASSERT(req != NULL);

    /* check verb */
    type = REQ_UNKNOWN;
    el = array_get(req->token, req->offset + CMD_OFFSET);

    ASSERT (el->type == ELEM_BULK);
    while (++type < REQ_SENTINEL &&
            bstring_compare(&command_table[type].bstr, &el->bstr) != 0) {}
    if (type == REQ_SENTINEL) {
        log_warn("unrecognized command detected: %.*s", el->bstr.len,
                el->bstr.data);
        return PARSE_EINVALID;
    }
    req->type = type;

    /* check narg */
    cmd = command_table[type];
    narg = req->token->nelem - req->offset - 1;
    if (narg < cmd.narg || narg > (cmd.narg + cmd.nopt)) {
        log_warn("wrong # of arguments for '%.*s': %d+[%d] expected, %d given",
                cmd.bstr.len, cmd.bstr.data, cmd.narg, cmd.nopt, narg);
        return PARSE_EINVALID;
    }

    return PARSE_OK;
}

static parse_rstatus_e
_parse_range(struct array *token, struct buf *buf, int64_t nelem)
{
    parse_rstatus_e status;
    struct element *el;

    while (nelem > 0) {
        if (buf_rsize(buf) == 0) {
            return PARSE_EUNFIN;
        }
        el = array_push(token);
        status = parse_element(el, buf);
        log_verb("parse element returned status %d", status);
        if (status != PARSE_OK) {
            return status;
        }
        nelem--;
    }

    return PARSE_OK;
}

parse_rstatus_e
parse_req(struct request *req, struct buf *buf)
{
    parse_rstatus_e status = PARSE_OK;
    char *old_rpos = buf->rpos;
    struct element *el;
    uint32_t cap = array_nalloc(req->token);

    ASSERT(cap > 1);

    log_verb("parsing buf %p into req %p", buf, req);

    if (buf_rsize(buf) == 0) {
        return PARSE_EUNFIN;
    }

    /* parse attributes if present */
    if (token_is_attrib(buf)) {
        cap--;
        el = array_push(req->token);
        status = parse_element(el, buf);
        if (status != PARSE_OK) {
            goto error;
        }
        /* each attrib takes 2 elements, which is why we divide cap by 2 (>>1),
         * we need at least another 2 token slots for the shortest command
         */
        if (el->num > (cap - 2) >> 1) {
            log_debug("too many attributes, %d is greater than %"PRIu32, el->num,
                    (cap - 2) >> 1);
            goto error;
        }
        cap -= el->num * 2;
        req->offset = 1 + el->num * 2;
        status = _parse_range(req->token, buf, el->num * 2);
        if (status != PARSE_OK) {
            goto error;
        }
    }

    cap--; /* we will have at least 2 slots here */
    el = array_push(req->token);
    status = parse_element(el, buf);
    if (status != PARSE_OK || el->num < 1) {
        goto error;
    }

    if (el->type != ELEM_ARRAY) {
        log_debug("parse req failed: not an array");
        return PARSE_EINVALID;
    }

    status = _parse_range(req->token, buf, el->num);
    if (status != PARSE_OK) {
        goto error;
    }

    status = _parse_cmd(req);
    if (status != PARSE_OK) {
        goto error;
    }

    return PARSE_OK;

error:
    request_reset(req);
    buf->rpos = old_rpos;
    return status;
}

parse_rstatus_e
parse_rsp(struct response *rsp, struct buf *buf)
{
    parse_rstatus_e status = PARSE_OK;
    char *old_rpos = buf->rpos;
    int64_t nelem = 1;
    struct element *el;
    uint32_t cap = array_nalloc(rsp->token);

    ASSERT(cap  > 0);
    ASSERT(rsp->type == ELEM_UNKNOWN);

    log_verb("parsing buf %p into rsp %p", buf, rsp);

    if (buf_rsize(buf) == 0) {
        return PARSE_EUNFIN;
    }

    /* parse attributes if present */
    if (token_is_attrib(buf)) {
        cap--;
        el = array_push(rsp->token);
        status = parse_element(el, buf);
        if (status != PARSE_OK) {
            goto error;
        }
        /* each attrib takes 2 elements, which is why we divide cap by 2 (>>1),
         * we need at least another token for the shortest response, hence -1
         */
        if (el->num > (cap - 1) >> 1) {
            log_debug("too many attributes, %d is greater than %"PRIu32, el->num,
                    (cap - 1) >> 1);
            goto error;
        }
        cap -= el->num * 2;
        rsp->offset = 1 + el->num * 2;
        status = _parse_range(rsp->token, buf, el->num * 2);
        if (status != PARSE_OK) {
            goto error;
        }
    }

    if (buf_rsize(buf) == 0) {
        return PARSE_EUNFIN;
    }

    if (token_is_array(buf)) {
        rsp->type = ELEM_ARRAY;
        cap--;
        el = array_push(rsp->token);
        status = parse_element(el, buf);
        if (status != PARSE_OK) {
            goto error;
        }
        nelem = el->num;
        if (nelem < 0) {
            rsp->nil = true;

            return PARSE_OK;
        }
    }

    status = _parse_range(rsp->token, buf, nelem);
    if (status != PARSE_OK) {
        goto error;
    }

    /* assign rsp type based on first non-attribute element */
    if (rsp->type == ELEM_UNKNOWN) {
        rsp->type =
            ((struct element *)array_get(rsp->token, rsp->offset))->type;
    }

    return PARSE_OK;

error:
    response_reset(rsp);
    buf->rpos = old_rpos;
    return status;
}
