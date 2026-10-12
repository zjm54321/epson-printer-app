/* Read-only Get-Printers client. Checks group tags, not just response status. */
#include <cups/cups.h>
#include <stdio.h>
#include <sys/socket.h>

int main(void) {
  http_t *http = httpConnect2("127.0.0.1", 8000, NULL, AF_UNSPEC,
                             HTTP_ENCRYPTION_IF_REQUESTED, 1, 3000, NULL);
  if (!http) {
    fputs("cannot connect to isolated loopback server\n", stderr);
    return 1;
  }
  ipp_t *request = ippNewRequest(IPP_OP_GET_PRINTERS);
  ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "system-uri", NULL,
               "ipp://127.0.0.1:8000/ipp/system");
  ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD,
               "requested-attributes", NULL, "all");
  ipp_t *response = cupsDoRequest(http, request, "/ipp/system");
  if (!response || ippGetStatusCode(response) != IPP_STATUS_OK) {
    fprintf(stderr, "Get-Printers failed: %s\n", cupsLastErrorString());
    if (response) ippDelete(response);
    httpClose(http);
    return 1;
  }
  for (ipp_attribute_t *attr = ippFirstAttribute(response); attr; attr = ippNextAttribute(response)) {
    if (ippGetGroupTag(attr) == IPP_TAG_PRINTER) {
      fputs("unexpected printer-attributes group: state is not queue-less\n", stderr);
      ippDelete(response);
      httpClose(http);
      return 1;
    }
  }
  ippDelete(response);
  httpClose(http);
  puts("PASS: Get-Printers returned zero printer-attributes groups");
  return 0;
}
