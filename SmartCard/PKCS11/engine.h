// C ABI of the Swift engine (Engine.swift) that pkcs11.c calls. Every function returns a CK_RV
// value and takes no PKCS#11 packed struct, so Swift never has to see the packed layouts.
#ifndef WSURF_ENGINE_H
#define WSURF_ENGINE_H

#include <stddef.h>

typedef unsigned long wsc_ulong;

enum { WSC_TEXT_READER = 0, WSC_TEXT_TOKEN_LABEL = 1 };

wsc_ulong wsc_initialize(void);
wsc_ulong wsc_finalize(void);

// ids NULL: only *count is set. *count too small: CKR_BUFFER_TOO_SMALL with *count = needed.
wsc_ulong wsc_slot_list(wsc_ulong *ids, wsc_ulong *count);
// Writes a NUL-terminated string truncated to cap.
wsc_ulong wsc_slot_text(wsc_ulong slot, int field, char *out, size_t cap);
// Either value is CK_UNAVAILABLE_INFORMATION (~0) when the card profile does not say.
wsc_ulong wsc_slot_pin_range(wsc_ulong slot, wsc_ulong *min, wsc_ulong *max);
// CKM_* values the slot's card profile can sign with; same *count rules as wsc_slot_list.
wsc_ulong wsc_slot_mechanisms(wsc_ulong slot, wsc_ulong *types, wsc_ulong *count);

wsc_ulong wsc_session_open(wsc_ulong slot, wsc_ulong *session);
wsc_ulong wsc_session_close(wsc_ulong session);
wsc_ulong wsc_session_close_all(wsc_ulong slot);
wsc_ulong wsc_session_info(wsc_ulong session, wsc_ulong *slot, int *logged_in);

wsc_ulong wsc_login(wsc_ulong session, wsc_ulong user_type, const unsigned char *pin, wsc_ulong pin_len);
wsc_ulong wsc_logout(wsc_ulong session);

// *len is the capacity of out on entry (ignored when out is NULL) and the attribute length on exit.
wsc_ulong wsc_attribute(wsc_ulong session, wsc_ulong object, wsc_ulong type, void *out, wsc_ulong *len);

wsc_ulong wsc_find_init(wsc_ulong session);
wsc_ulong wsc_find_filter(wsc_ulong session, wsc_ulong type, const void *value, wsc_ulong len);
wsc_ulong wsc_find_next(wsc_ulong session, wsc_ulong max, wsc_ulong *objects, wsc_ulong *count);
wsc_ulong wsc_find_final(wsc_ulong session);

wsc_ulong wsc_sign_init(wsc_ulong session, wsc_ulong mechanism, wsc_ulong key);
wsc_ulong wsc_sign(wsc_ulong session, const unsigned char *data, wsc_ulong data_len,
                   unsigned char *signature, wsc_ulong *signature_len);

#endif
