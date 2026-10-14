// Prüfhilfe (Tests, Selbsttest): Speicheranforderungen eines Threads zählen – belegt, dass der Render-Pfad nichts anfordert.
#ifndef MIXDSP_ALLOC_PROBE_H
#define MIXDSP_ALLOC_PROBE_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// ab jetzt Anforderungen (malloc & Co.) des aufrufenden Threads zählen; nur ein Zähler gleichzeitig
void mdsp_alloc_probe_begin(void);
/// zählen beenden, liefert die Anzahl seit begin
int64_t mdsp_alloc_probe_end(void);

#ifdef __cplusplus
}
#endif
#endif
