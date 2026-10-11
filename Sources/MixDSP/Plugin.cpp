// Verteiler für MDPlugin: der Kern ruft mdplug_process(), das Backend (AU, VST3) rechnet.
#include "MixDSPPlugin.h"
#include "PluginBackend.h"

static_assert(int(MDPLUG_AU) == int(MDPLUG_KIND_AU) && int(MDPLUG_VST3) == int(MDPLUG_KIND_VST3), "Formate");

extern "C" {

int mdplug_format(MDPlugin *p) { return p ? p->kind : 0; }

void mdplug_close(MDPlugin *p) { delete p; }

void mdplug_reset(MDPlugin *p) { if (p) p->reset(); }

void mdplug_process(MDPlugin *p, float *L, float *R, int n) { if (p) p->process(L, R, n); }

} // extern "C"
