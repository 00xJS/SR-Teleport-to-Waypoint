/*
 * Teleport to Waypoint - position readout (native part, Windows).
 *
 * Lua mods have no way to draw text that stays on screen; native mods do
 * (overlay_text, the same call the trainer uses). This draws the player's
 * x, y, z in the corner every frame while on. The key is `coords_key` in
 * mod.ini (default 9), the same one main.lua reads to log the position.
 *
 * Build (any 64-bit C compiler; here the SDK's clang):
 *   clang -shared -O2 -I <SaintsReborn>/modding/include -o coords.dll coords.c
 */
#define _CRT_SECURE_NO_WARNINGS
#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wml.h"

#define PLAYER 0x8309ABECu        /* pointer to the player object (0 = no game) */
#define MULTIPLAYER 0x8370E9F6u

static const WmlApi* api;
static int visible = 0;
static int key = '9';

/* Key names as the Lua side takes them: a letter, a digit, F1-F12, or a
   Windows virtual-key number. Empty means no key. Returns 0 for none. */
static int parse_key(const char* s) {
  while (*s == ' ' || *s == '\t') s++;
  size_t n = strlen(s);
  while (n && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\r' || s[n - 1] == '\n')) n--;
  if (n == 0) return 0;
  if (n == 1) return toupper((unsigned char)s[0]);
  if ((s[0] == 'F' || s[0] == 'f') && n <= 3) {
    int f = atoi(s + 1);
    if (f >= 1 && f <= 12) return 0x70 + f - 1;
  }
  int code = atoi(s);
  return code > 0 && code < 256 ? code : 0;
}

/* coords_key from this mod's mod.ini (the native API has no settings call). */
static void read_key(const WmlMod* mod) {
  char path[1024];
  snprintf(path, sizeof path, "%s/mod.ini", mod->folder);
  FILE* f = fopen(path, "r");
  if (!f) return;
  char line[256];
  while (fgets(line, sizeof line, f)) {
    const char* p = line;
    while (*p == ' ' || *p == '\t') p++;
    if (strncmp(p, "coords_key", 10) != 0) continue;
    p += 10;
    while (*p == ' ' || *p == '\t') p++;
    if (*p != '=') continue;
    key = parse_key(p + 1);
    break;
  }
  fclose(f);
}

static int readable_player(uint32_t p) {
  return p >= 0x10000u && p < 0xFFFF0000u && api->read_u32(p + 72) == 1;
}

static void on_frame(void* user) {
  (void)user;
  if (key && api->key_pressed(key)) visible = !visible;
  if (!visible) { api->overlay_text(""); return; }
  uint32_t p = api->read_u32(PLAYER);
  char text[160];
  if (!readable_player(p)) {
    snprintf(text, sizeof text, "Position: no game loaded");
  } else {
    float x = api->read_f32(p + 20), y = api->read_f32(p + 24), z = api->read_f32(p + 28);
    int in_vehicle = api->read_u32(p + 2496) != 0;
    snprintf(text, sizeof text, "X %8.1f   Y %7.1f   Z %8.1f%s%s", x, y, z,
             in_vehicle ? "   (in a vehicle)" : "",
             api->read_u8(MULTIPLAYER) ? "   (multiplayer)" : "");
  }
  api->overlay_text(text);
}

WML_EXPORT int wml_mod_init(const WmlApi* loader, const WmlMod* mod) {
  if (!loader || loader->version != WML_API_VERSION || loader->size < sizeof(WmlApi) || !loader->overlay_text) return 1;
  api = loader;
  read_key(mod);
  api->on_frame(on_frame, 0);
  char msg[96];
  snprintf(msg, sizeof msg, "Position readout loaded (key code %d toggles it).", key);
  api->log(mod, msg);
  return 0;
}
