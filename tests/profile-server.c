/* Test-only adapter around the LOCKED application's main, linked to the same
 * shared libraries as production. Exported separately, never in /runtime.
 * No mapping/filter implementation is copied here: callbacks only assert
 * actual driver data/raster geometry and delegate to the real library.
 */
#include "pappl-retrofit-private.h"
#include <assert.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *root;
static int test_app(pr_printer_app_config_t *config, int argc, char **argv);
#define main upstream_main
#define prRetroFitPrinterApp test_app
#include "ghostscript-printer-app.c"
#undef prRetroFitPrinterApp
#undef main

static void path(char *buffer, size_t size, const char *name) {
  assert(snprintf(buffer, size, "%s/%s", root, name) < (int)size);
}

static bool sink_open(pappl_device_t *device, const char *uri, const char *name) {
  char filename[1024];
  (void)name;
  if (strcmp(uri, "offline:profile-test")) return false;
  path(filename, sizeof(filename), "output.bin");
  int fd = open(filename, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
  if (fd < 0) return false;
  int *saved = malloc(sizeof(int));
  assert(saved);
  *saved = fd;
  papplDeviceSetData(device, saved);
  return true;
}

static void sink_close(pappl_device_t *device) {
  int *fd = papplDeviceGetData(device);
  close(*fd);
  free(fd);
}

static ssize_t sink_write(pappl_device_t *device, const void *buffer, size_t bytes) {
  return write(*(int *)papplDeviceGetData(device), buffer, bytes);
}

static bool checked_page(pappl_job_t *job, pappl_pr_options_t *options,
                         pappl_device_t *device, unsigned page) {
  char filename[1024];
  cups_page_header2_t expected;
  assert(!strcmp(papplJobGetFormat(job), "image/pwg-raster"));
  path(filename, sizeof(filename), "gray.pwg");
  int fd = open(filename, O_RDONLY);
  assert(fd >= 0);
  cups_raster_t *raster = cupsRasterOpen(fd, CUPS_RASTER_READ);
  assert(raster && cupsRasterReadHeader2(raster, &expected));
  cupsRasterClose(raster);
  close(fd);
  assert(expected.HWResolution[0] == 120 && expected.HWResolution[1] == 72);
  assert(expected.cupsBitsPerPixel == 8 && expected.cupsColorSpace == CUPS_CSPACE_SW);
  assert(options->print_quality == IPP_QUALITY_DRAFT);
  assert(options->printer_resolution[0] == 360 && options->printer_resolution[1] == 360);
  // Entire decoded client header, not just HWResolution or dimensions.
  assert(!memcmp(&options->header, &expected, sizeof(expected)));
  assert(prPSRasterStartPage(job, options, device, page));
  assert(!memcmp(&options->header, &expected, sizeof(expected)));
  pr_job_data_t *data = papplJobGetData(job);
  assert(data && data->stream_format->rstartpage_cb == prPSRasterStartPage);
  assert(!strcmp(data->stream_format->dsttype, "application/vnd.cups-postscript"));
  assert(!strcmp(cupsGetOption("Resolution", data->filter_data->num_options,
                               data->filter_data->options), "360x216dpi"));
  papplLogJob(job, PAPPL_LOGLEVEL_INFO,
              "PROFILE HEADER PASS %ux%u row=%u bits=%u dpi=%ux%u logical=360x360dpi output=360x216dpi",
              expected.cupsWidth, expected.cupsHeight, expected.cupsBytesPerLine,
              expected.cupsBitsPerPixel, expected.HWResolution[0], expected.HWResolution[1]);
  return true;
}

static bool checked_setup(pappl_system_t *system, const char *driver,
                          const char *uri, const char *id,
                          pappl_pr_driver_data_t *data, ipp_t **attrs, void *global) {
  if (!_prDriverSetup(system, driver, uri, id, data, attrs, global)) return false;
  assert(data->rstartpage_cb == prPSRasterStartPage);
  data->rstartpage_cb = checked_page;
  return true;
}

static void test_setup(void *data) {
  pr_printer_app_global_data_t *global = data;
  // No production device, discovery, USB or writable-file backend is usable.
  papplDeviceRemoveTypes(PAPPL_DEVTYPE_ALL);
  papplDeviceAddScheme("offline", PAPPL_DEVTYPE_CUSTOM_LOCAL, NULL, sink_open,
                       sink_close, NULL, sink_write, NULL, NULL);
  papplSystemSetPrinterDrivers(global->system, global->num_drivers, global->drivers,
                               NULL, NULL, checked_setup, global);
}

static int test_app(pr_printer_app_config_t *config, int argc, char **argv) {
  config->extra_setup_cb = test_setup;
  return prRetroFitPrinterApp(config, argc, argv);
}

int main(int argc, char **argv) {
  struct stat st;
  static char program_name[] = "ghostscript-printer-app";
  root = getenv("PROFILE_TEST_ROOT");
  if (!root || strncmp(root, "/tmp/", 5) || strstr(root, "..") ||
      lstat(root, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() ||
      !access("/dev/bus/usb", F_OK)) return 1;
  // PAPPL derives its same-UID socket basename from argv[0], not the config.
  // Keep the instrumented server on the production CLI/queue-check identity.
  argv[0] = program_name;
  return upstream_main(argc, argv);
}
