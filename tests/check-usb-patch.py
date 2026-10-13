#!/usr/bin/env python3
"""Two focused checks against patched CUPS source; no USB or PDF access."""
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()
start = source.index("\nget_device_id(usb_printer_t") + 1
end = source.index("\n}\n", start) + 3
function = "static int\n" + source[start:end]
# Compile the actual patched function with a deterministic control-transfer stub.
# Test failed/short/truncated replies and a valid MSB/LSB response; no hardware.
prefix = r'''
#include <string.h>
#include <stddef.h>
#include <assert.h>
typedef struct {void *handle; int conf, iface, altset;} usb_printer_t;
#define LIBUSB_REQUEST_TYPE_CLASS 0
#define LIBUSB_ENDPOINT_IN 0
#define LIBUSB_RECIPIENT_INTERFACE 0
static int response;
static unsigned char payload[64];
static int libusb_control_transfer(void *h,int a,int b,int c,int d,unsigned char *out,size_t cap,int t) {
  (void)h;(void)a;(void)b;(void)c;(void)d;(void)t;
  if(response > 0) memcpy(out,payload,(size_t)response < cap ? (size_t)response : cap);
  return response;
}
'''
main = r'''
int main(void) {
  usb_printer_t p={0}; char out[64];
  for(int n=-1;n<=1;n++) {
    response=n; memset(out,0x7f,sizeof(out));
    assert(get_device_id(&p,out,sizeof(out)) == -1 && out[0] == 0);
  }
  response=14; payload[0]=0; payload[1]=40;
  assert(get_device_id(&p,out,sizeof(out)) == -1 && out[0] == 0);
  payload[0]=0; payload[1]=14; memcpy(payload+2,"MFG:x;MDL:y;",12);
  assert(get_device_id(&p,out,sizeof(out)) == 0 && !strcmp(out,"MFG:x;MDL:y;"));
  payload[0]=14; payload[1]=0;
  assert(get_device_id(&p,out,sizeof(out)) == 0 && !strcmp(out,"MFG:x;MDL:y;"));
  return 0;
}
'''
with tempfile.TemporaryDirectory(prefix="cups-usb-regression-") as directory:
    path = Path(directory)
    (path / "check.c").write_text(prefix + function + main)
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", str(path / "check.c"), "-o", str(path / "check")], check=True)
    subprocess.run([str(path / "check")], check=True)
print("PASS USB check 1: actual get_device_id rejects short/truncated responses")
uri = source[source.index("make_device_uri(\n"):source.index("\n/*\n * 'open_device()'")]
bridge = uri[uri.index("if (devdesc.idVendor == 0x1a86"):uri.index('if ((mfg = cupsGetOption("MANUFACTURER"')]
assert "devdesc.idProduct == 0x7584" in bridge
assert "libusb_get_string_descriptor_ascii" in bridge
assert "cupsGetOption" not in bridge and "device_id" not in bridge
assert 'mfg = tempmfg[0] ? tempmfg : tempmdl;' in bridge
assert 'mdl = tempmfg[0] ? tempmdl : "";' in bridge
assert "get_serial_number(printer, devdesc.iSerialNumber" in uri
trim = bridge[bridge.index("    for (i = 0; i < 2; i ++)"):bridge.index("    mfg = tempmfg[0]")]
with tempfile.TemporaryDirectory(prefix="cups-uri-regression-") as directory:
    path = Path(directory)
    harness = '#include <string.h>\n#include <assert.h>\nstatic int normalize(char *tempmfg,char *tempmdl) {\nint i,length; char *tempptr;\n'
    harness += trim + '\nreturn 0;\nbridge_invalid: return -1;\n}\n'
    harness += r'''int main(void) {
      char mfg[256]="   ", mdl[256]=" USB2.0-Print ";
      assert(normalize(mfg,mdl)==0);
      assert(!strcmp(mfg,"") && !strcmp(mdl,"USB2.0-Print"));
      strcpy(mdl,"   ");
      assert(normalize(mfg,mdl)==-1);
      return 0;
    }'''
    (path / "check.c").write_text(harness)
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", str(path / "check.c"), "-o", str(path / "check")], check=True)
    subprocess.run([str(path / "check")], check=True)
print("PASS USB check 2: bridge URI uses USB descriptors; other vendors retain original path")
