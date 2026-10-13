/* Test-only adapter around the LOCKED application's main, linked to the same
 * shared libraries as production. Exported separately, never in /runtime.
 * No mapping/filter implementation is copied here: callbacks only assert
 * actual driver data/raster geometry and delegate to the real library.
 */
#include "pappl-retrofit-private.h"
#include "print-job-private.h"
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
  const char *name = papplJobGetName(job);
  char filename[1024], resolution[64];
  cups_page_header2_t expected;
  assert(!strcmp(papplJobGetDocumentFormat(job, 1), "image/pwg-raster"));
  path(filename, sizeof(filename), !strncmp(name, "black-", 6) ? "black.pwg" : "gray.pwg");
  int fd = open(filename, O_RDONLY);
  assert(fd >= 0);
  cups_raster_t *raster = cupsRasterOpen(fd, CUPS_RASTER_READ);
  assert(raster && cupsRasterReadHeader2(raster, &expected));
  cupsRasterClose(raster);
  close(fd);
  // Entire decoded client header, not just HWResolution or dimensions.
  assert(!memcmp(&options->header, &expected, sizeof(expected)));
  assert(prPSRasterStartPage(job, options, device, page));
  assert(!memcmp(&options->header, &expected, sizeof(expected)));
  pr_job_data_t *data = papplJobGetData(job);
  assert(data && data->stream_format->rstartpage_cb == prPSRasterStartPage);
  assert(!strcmp(data->stream_format->dsttype, "application/vnd.cups-postscript"));
  snprintf(resolution, sizeof(resolution), "%dx%ddpi",
           options->printer_resolution[0], options->printer_resolution[1]);
  assert(!strcmp(cupsGetOption("Resolution", data->filter_data->num_options,
                               data->filter_data->options), resolution));
  papplLogJob(job, PAPPL_LOGLEVEL_INFO,
              "PROFILE HEADER PASS %ux%u row=%u bits=%u dpi=%ux%u output=%s",
              expected.cupsWidth, expected.cupsHeight, expected.cupsBytesPerLine,
              expected.cupsBitsPerPixel, expected.HWResolution[0], expected.HWResolution[1], resolution);
  return true;
}

static void check_driver(pappl_pr_driver_data_t *data) {
  static const int xy[4][2] = {{60,60}, {120,72}, {180,180}, {360,216}};
  pr_driver_extension_t *extension = data->extension;
  assert(extension->epson_mono_profile && !extension->ppd->color_device);
  assert(data->num_resolution == 4);
  for (int i = 0; i < 4; i++) {
    char choice[64];
    assert(data->x_resolution[i] == xy[i][0] && data->y_resolution[i] == xy[i][1]);
    snprintf(choice, sizeof(choice), "%dx%ddpi", xy[i][0], xy[i][1]);
    assert(ppdFindChoice(ppdFindOption(extension->ppd, "Resolution"), choice));
  }
  assert(data->color_supported == PAPPL_COLOR_MODE_MONOCHROME);
  assert(data->color_default == PAPPL_COLOR_MODE_MONOCHROME && data->ppm_color == 0);
  assert(data->raster_types == (PAPPL_RASTER_TYPE_BLACK_1 | PAPPL_RASTER_TYPE_SGRAY_8));
  assert(!data->force_raster_type);
  assert(extension->stream_format->rstartpage_cb == prPSRasterStartPage);
  for (int i = 0; i < data->num_vendor; i++)
    assert(!strstr(extension->vendor_ppd_options[i], "Resolution"));
}

static bool checked_setup(pappl_system_t *system, const char *driver,
                          const char *uri, const char *id,
                          pappl_pr_driver_data_t *data, ipp_t **attrs, void *global) {
  bool initial = !data->extension;
  if (!_prDriverSetup(system, driver, uri, id, data, attrs, global)) return false;
  check_driver(data);
  if (initial) {
    assert(data->x_default == 180 && data->y_default == 180);
    assert(data->quality_default == IPP_QUALITY_NORMAL);
    // Exercise the real NULL-driver-name update path: reject the former
    // heuristic pair, while retaining an explicitly valid user default.
    data->x_default = 360; data->y_default = 180;
    assert(_prDriverSetup(system, NULL, NULL, NULL, data, attrs, global));
    assert(data->x_default == 180 && data->y_default == 180);
    data->x_default = 120; data->y_default = 72;
    assert(_prDriverSetup(system, NULL, NULL, NULL, data, attrs, global));
    assert(data->x_default == 120 && data->y_default == 72);
    check_driver(data);
    data->x_default = data->y_default = 180;
    // Allow the normal post-load status callback to reconcile retained state.
    ((pr_driver_extension_t *)data->extension)->updated = false;
    papplLog(system, PAPPL_LOGLEVEL_INFO, "PROFILE CAPS/UPDATE PASS");
  }
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
  root = getenv("PROFILE_TEST_ROOT");
  if (!root || strncmp(root, "/tmp/", 5) || strstr(root, "..") ||
      lstat(root, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() ||
      !access("/dev/bus/usb", F_OK)) return 1;
  return upstream_main(argc, argv);
}
