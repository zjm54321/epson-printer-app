/* One owned sgray_8 PWG fixture and ESC/P output assertions using real libcups. */
#include <cups/cups.h>
#include <cups/pwg.h>
#include <cups/raster.h>
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
  assert(argc == 3);
  if (!strcmp(argv[1], "web")) {
    // Read-only loopback HTTP check inside the isolated test network.
    http_t *http = httpConnect2("127.0.0.1", 8000, NULL, AF_UNSPEC,
                               HTTP_ENCRYPTION_IF_REQUESTED, 1, 3000, NULL);
    assert(http && argv[2][0] == '/');
    httpSetTimeout(http, 5.0, NULL, NULL);
    httpSetField(http, HTTP_FIELD_HOST, "127.0.0.1:8000");
    assert(httpGet(http, argv[2]) == 0);
    http_status_t status;
    do { status = httpUpdate(http); } while (status == HTTP_STATUS_CONTINUE);
    assert(status == HTTP_STATUS_OK);
    httpFlush(http);
    httpClose(http);
    puts("PASS canonical web resource returns HTTP 200");
    return 0;
  }
  if (!strcmp(argv[1], "output")) {
    FILE *f = fopen(argv[2], "rb");
    unsigned char data[4096];
    assert(f);
    size_t bytes, total = 0;
    int previous = -1, escp = 0;
    while ((bytes = fread(data, 1, sizeof(data), f)) > 0) {
      if (!total) assert(memcmp(data, "%!PS", 4) && memcmp(data, "%PDF", 4));
      for (size_t i = 0; i < bytes; i++) {
        if (previous == 27 && (data[i] == '@' || data[i] == '*' || data[i] == '(')) escp = 1;
        previous = data[i];
      }
      total += bytes;
    }
    assert(!ferror(f) && total > 4 && escp);
    fclose(f);
    printf("PASS real filter ESC/P output: %zu bytes\n", total);
    return 0;
  }
  assert(!strcmp(argv[1], "gray"));
  int fd = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, 0600);
  assert(fd >= 0);
  cups_raster_t *raster = cupsRasterOpen(fd, CUPS_RASTER_WRITE_PWG);
  cups_page_header2_t header;
  pwg_media_t *media = pwgMediaForPWG("iso_a4_210x297mm");
  assert(raster && media);
  assert(cupsRasterInitPWGHeader(&header, media, "sgray_8",
                                 120, 72, "one-sided", "normal"));
  header.cupsInteger[CUPS_RASTER_PWG_TotalPageCount] = 1;
  assert(cupsRasterWriteHeader2(raster, &header));
  unsigned char *row = malloc(header.cupsBytesPerLine);
  assert(row);
  for (unsigned y = 0; y < header.cupsHeight; y++) {
    memset(row, 255, header.cupsBytesPerLine);
    // An owned asymmetric stripe and gray ramp, not a blank page.
    if (y >= 40 && y < 80)
      for (unsigned x = 8; x < header.cupsBytesPerLine / 2; x++)
        row[x] = (unsigned char)(x % 192);
    assert(cupsRasterWritePixels(raster, row, header.cupsBytesPerLine) == header.cupsBytesPerLine);
  }
  free(row);
  cupsRasterClose(raster);
  close(fd);
  return 0;
}
