/* Read-only bootstrap contract: queue-check exists|ready QUEUE DRIVER DEVICE_URI.
 * ready also accepts a final optional expected DNS-SD display name.
 * 0 = exact match (and ready profile); 4 = exists + explicit IPP not-found only;
 * 1 = every other failure. Same-UID Unix socket only; no fallback or mutation.
 */
#include <cups/cups.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static const char profile[] = "generic--esc-p-dot-matrix-printer--epson-recommended-en";

static bool identifier(const char *s, size_t max) {
  size_t len = strlen(s);
  if (!len || len > max) return false;
  for (; *s; s++)
    if (!((*s >= 'a' && *s <= 'z') || (*s >= 'A' && *s <= 'Z') ||
          (*s >= '0' && *s <= '9') || *s == '-' || *s == '_')) return false;
  return true;
}

static bool printable(const char *s) {
  for (; *s; s++) if ((unsigned char)*s <= 32 || (unsigned char)*s == 127) return false;
  return true;
}

static bool device_uri(const char *s) {
  const char *colon = strchr(s, ':');
  if (!colon || colon == s || !colon[1] || strlen(s) > 2048 || !printable(s) ||
      !((*s >= 'a' && *s <= 'z') || (*s >= 'A' && *s <= 'Z'))) return false;
  for (const char *p = s + 1; p < colon; p++)
    if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
          (*p >= '0' && *p <= '9') || *p == '+' || *p == '-' || *p == '.')) return false;
  return true;
}

static bool dnssd_name(const char *s) {
  if (!*s || strlen(s) > 63) return false;
  ipp_t *message = ippNew();
  ipp_attribute_t *name = ippAddString(message, IPP_TAG_PRINTER, IPP_TAG_NAME,
                                       "printer-dns-sd-name", NULL, s);
  bool valid = name && ippValidateAttribute(name);
  ippDelete(message);
  return valid;
}

static const char *no_password(const char *prompt, http_t *http,
                               const char *method, const char *resource, void *data) {
  (void)prompt; (void)http; (void)method; (void)resource; (void)data;
  return NULL;
}

static ipp_attribute_t *attribute(ipp_t *response, const char *name, ipp_tag_t tag,
                                  ipp_tag_t group, int count) {
  ipp_attribute_t *a = ippFindAttribute(response, name, tag);
  return a && ippGetGroupTag(a) == group && ippGetCount(a) == count ? a : NULL;
}

static bool string_is(ipp_t *response, const char *name, ipp_tag_t tag, const char *value) {
  ipp_attribute_t *a = attribute(response, name, tag, IPP_TAG_PRINTER, 1);
  const char *s = a ? ippGetString(a, 0, NULL) : NULL;
  return s && !strcmp(s, value);
}

static bool resolutions(ipp_t *response, const char *name, bool defaults) {
  // Frontend compatibility DPI; the PPD's physical ESC/P pairs are separate.
  static const int xy[4][2] = {{60,60}, {120,120}, {180,180}, {360,360}};
  int count = defaults ? 1 : 4;
  ipp_attribute_t *a = attribute(response, name, IPP_TAG_RESOLUTION, IPP_TAG_PRINTER, count);
  if (!a) return false;
  for (int i = 0; i < count; i++) {
    int y;
    ipp_res_t units;
    int x = ippGetResolution(a, i, &y, &units);
    int n = defaults ? 2 : i;
    if (units != IPP_RES_PER_INCH || x != xy[n][0] || y != xy[n][1]) return false;
  }
  return true;
}

static bool capabilities(ipp_t *response) {
  if (!resolutions(response, "printer-resolution-supported", false) ||
      !resolutions(response, "pwg-raster-document-resolution-supported", false) ||
      !resolutions(response, "printer-resolution-default", true) ||
      !string_is(response, "print-color-mode-supported", IPP_TAG_KEYWORD, "monochrome") ||
      !string_is(response, "print-color-mode-default", IPP_TAG_KEYWORD, "monochrome")) return false;
  ipp_attribute_t *a = attribute(response, "print-quality-default", IPP_TAG_ENUM, IPP_TAG_PRINTER, 1);
  if (!a || ippGetInteger(a, 0) != IPP_QUALITY_NORMAL) return false;
  a = attribute(response, "print-quality-supported", IPP_TAG_ENUM, IPP_TAG_PRINTER, 3);
  if (!a || !ippContainsInteger(a, IPP_QUALITY_DRAFT) ||
      !ippContainsInteger(a, IPP_QUALITY_NORMAL) || !ippContainsInteger(a, IPP_QUALITY_HIGH)) return false;
  a = attribute(response, "pwg-raster-document-type-supported", IPP_TAG_KEYWORD, IPP_TAG_PRINTER, 2);
  if (!a || !ippContainsString(a, "black_1") || !ippContainsString(a, "sgray_8")) return false;
  a = attribute(response, "color-supported", IPP_TAG_BOOLEAN, IPP_TAG_PRINTER, 1);
  if (!a || ippGetBoolean(a, 0)) return false;
  a = ippFindAttribute(response, "pages-per-minute-color", IPP_TAG_ZERO);
  if (a && (ippGetValueTag(a) != IPP_TAG_INTEGER || ippGetCount(a) != 1 || ippGetInteger(a, 0))) return false;
  for (a = ippFirstAttribute(response); a; a = ippNextAttribute(response)) {
    const char *name = ippGetName(a);
    if (name && strstr(name, "resolution") &&
        strcmp(name, "printer-resolution-supported") &&
        strcmp(name, "printer-resolution-default") &&
        strcmp(name, "pwg-raster-document-resolution-supported")) return false;
    if (name && !strcmp(name, "job-creation-attributes-supported")) {
      for (int i = 0; i < ippGetCount(a); i++) {
        const char *value = ippGetString(a, i, NULL);
        if (value && strstr(value, "resolution") && strcmp(value, "printer-resolution")) return false;
      }
    }
  }
  return true;
}

static ipp_t *query(http_t *http, ipp_op_t operation, const char *resource) {
  char uri[512];
  snprintf(uri, sizeof(uri), "ipp://localhost%s", resource);
  ipp_t *request = ippNewRequest(operation);
  ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI,
               operation == IPP_OP_GET_SYSTEM_ATTRIBUTES ? "system-uri" : "printer-uri", NULL, uri);
  ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, cupsUser());
  ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes", NULL, "all");
  return cupsDoRequest(http, request, resource);
}

int main(int argc, char **argv) {
  bool ready;
  int result = 1, printer_id;
  char socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)], resource[256];
  const char *tmp = getenv("TMPDIR");
  if ((argc != 5 && argc != 6) || (strcmp(argv[1], "exists") && strcmp(argv[1], "ready"))) {
    fputs("usage: queue-check exists QUEUE DRIVER DEVICE_URI\n"
          "       queue-check ready QUEUE DRIVER DEVICE_URI [DNSSD_NAME]\n", stderr);
    return 1;
  }
  ready = !strcmp(argv[1], "ready");
  if (!identifier(argv[2], 127) || !identifier(argv[3], 255) ||
      !device_uri(argv[4]) ||
      (argc == 6 && (!ready || !dnssd_name(argv[5]))) ||
      (ready && strcmp(argv[3], profile))) {
    fputs("queue-check: invalid arguments\n", stderr);
    return 1;
  }
  if (!tmp || !*tmp) tmp = "/tmp";
  if (tmp[0] != '/' || !printable(tmp) || strstr(tmp, "/../") || strstr(tmp, "/./") ||
      !strcmp(tmp, "/..") || !strcmp(tmp, "/.") ||
      (strlen(tmp) >= 3 && !strcmp(tmp + strlen(tmp) - 3, "/..")) ||
      (strlen(tmp) >= 2 && !strcmp(tmp + strlen(tmp) - 2, "/.")) ||
      snprintf(socket_path, sizeof(socket_path), "%s/ghostscript-printer-app%lu.sock", tmp,
               (unsigned long)getuid()) >= (int)sizeof(socket_path)) {
    fputs("queue-check: invalid socket directory\n", stderr);
    return 1;
  }
  cupsSetPasswordCB2(no_password, NULL);
  struct stat socket_stat;
  if (lstat(socket_path, &socket_stat) || !S_ISSOCK(socket_stat.st_mode) || socket_stat.st_uid != getuid()) {
    fputs("queue-check: same-UID socket unavailable\n", stderr);
    return 1;
  }
  http_t *http = httpConnect2(socket_path, 8000, NULL, AF_UNSPEC,
                             HTTP_ENCRYPTION_IF_REQUESTED, 1, 3000, NULL);
  if (!http) {
    fputs("queue-check: same-UID socket connection failed\n", stderr);
    return 1;
  }
  httpSetTimeout(http, 5.0, NULL, NULL);
  snprintf(resource, sizeof(resource), "/ipp/print/%s", argv[2]);
  ipp_t *response = query(http, IPP_OP_GET_PRINTER_ATTRIBUTES, resource);
  if (response && ippGetStatusCode(response) == IPP_STATUS_ERROR_NOT_FOUND) {
    result = ready ? 1 : 4;
    goto done;
  }
  if (!response || ippGetStatusCode(response) != IPP_STATUS_OK) goto done;
  if (!string_is(response, "printer-name", IPP_TAG_NAME, argv[2]) ||
      !string_is(response, "smi55357-driver", IPP_TAG_KEYWORD, argv[3]) ||
      !string_is(response, "smi55357-device-uri", IPP_TAG_URI, argv[4])) goto done;
  if (!ready) { result = 0; goto done; }
  if (argc == 6 && !string_is(response, "printer-dns-sd-name", IPP_TAG_NAME, argv[5])) goto done;
  if (!capabilities(response)) goto done;
  ipp_attribute_t *id = attribute(response, "printer-id", IPP_TAG_INTEGER, IPP_TAG_PRINTER, 1);
  if (!id || (printer_id = ippGetInteger(id, 0)) <= 0) goto done;
  ippDelete(response);
  response = query(http, IPP_OP_GET_SYSTEM_ATTRIBUTES, "/ipp/system");
  if (!response || ippGetStatusCode(response) != IPP_STATUS_OK) goto done;
  id = attribute(response, "system-default-printer-id", IPP_TAG_INTEGER, IPP_TAG_SYSTEM, 1);
  if (id && ippGetInteger(id, 0) == printer_id) result = 0;
done:
  if (response) ippDelete(response);
  httpClose(http);
  if (result) fputs(result == 4 ? "queue-check: queue not found\n" :
                   "queue-check: identity/readiness query failed\n", stderr);
  else puts(ready ? "queue-check: ready" : "queue-check: exists");
  return result;
}
