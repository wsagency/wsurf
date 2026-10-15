// PKCS#11 v2.40 entry points. This file owns the packed ABI structs and the function table;
// all card/session logic lives in the Swift engine behind engine.h.
#include <string.h>

#include "engine.h"
#include "pkcs11.h"

static void put_text(CK_UTF8CHAR *dst, size_t size, const char *src) {
    size_t n = strlen(src);
    if (n > size) n = size;
    memset(dst, ' ', size);
    memcpy(dst, src, n);
}

CK_RV C_Initialize(CK_VOID_PTR pInitArgs) {
    if (pInitArgs != NULL) {
        const CK_C_INITIALIZE_ARGS *args = pInitArgs;
        if (args->pReserved != NULL) return CKR_ARGUMENTS_BAD;
        int callbacks = (args->CreateMutex != NULL) + (args->DestroyMutex != NULL) +
                        (args->LockMutex != NULL) + (args->UnlockMutex != NULL);
        if (callbacks != 0 && callbacks != 4) return CKR_ARGUMENTS_BAD;
        // The engine serialises with its own NSLock; caller-supplied mutexes cannot be honoured.
        if (callbacks == 4 && !(args->flags & CKF_OS_LOCKING_OK)) return CKR_CANT_LOCK;
    }
    return wsc_initialize();
}

CK_RV C_Finalize(CK_VOID_PTR pReserved) {
    if (pReserved != NULL) return CKR_ARGUMENTS_BAD;
    return wsc_finalize();
}

CK_RV C_GetInfo(CK_INFO *pInfo) {
    if (pInfo == NULL) return CKR_ARGUMENTS_BAD;
    memset(pInfo, 0, sizeof *pInfo);
    pInfo->cryptokiVersion = (CK_VERSION){2, 40};
    put_text(pInfo->manufacturerID, sizeof pInfo->manufacturerID, "WSurf");
    put_text(pInfo->libraryDescription, sizeof pInfo->libraryDescription, "WSurf Smart Card PKCS#11");
    pInfo->libraryVersion = (CK_VERSION){0, 1};
    return CKR_OK;
}

extern CK_FUNCTION_LIST wsurf_function_list;

CK_RV C_GetFunctionList(CK_FUNCTION_LIST **ppFunctionList) {
    if (ppFunctionList == NULL) return CKR_ARGUMENTS_BAD;
    *ppFunctionList = &wsurf_function_list;
    return CKR_OK;
}

CK_RV C_GetSlotList(CK_BBOOL tokenPresent, CK_SLOT_ID_PTR pSlotList, CK_ULONG_PTR pulCount) {
    // Every slot is a reader holding a supported card, so tokenPresent does not filter.
    (void)tokenPresent;
    if (pulCount == NULL) return CKR_ARGUMENTS_BAD;
    return wsc_slot_list(pSlotList, pulCount);
}

CK_RV C_GetSlotInfo(CK_SLOT_ID slotID, CK_SLOT_INFO *pInfo) {
    if (pInfo == NULL) return CKR_ARGUMENTS_BAD;
    char reader[65];
    CK_RV rv = wsc_slot_text(slotID, WSC_TEXT_READER, reader, sizeof reader);
    if (rv != CKR_OK) return rv;
    memset(pInfo, 0, sizeof *pInfo);
    put_text(pInfo->slotDescription, sizeof pInfo->slotDescription, reader);
    put_text(pInfo->manufacturerID, sizeof pInfo->manufacturerID, "WSurf");
    pInfo->flags = CKF_TOKEN_PRESENT | CKF_REMOVABLE_DEVICE | CKF_HW_SLOT;
    return CKR_OK;
}

CK_RV C_GetTokenInfo(CK_SLOT_ID slotID, CK_TOKEN_INFO *pInfo) {
    if (pInfo == NULL) return CKR_ARGUMENTS_BAD;
    char label[33];
    CK_RV rv = wsc_slot_text(slotID, WSC_TEXT_TOKEN_LABEL, label, sizeof label);
    if (rv != CKR_OK) return rv;
    CK_ULONG minPin, maxPin;
    rv = wsc_slot_pin_range(slotID, &minPin, &maxPin);
    if (rv != CKR_OK) return rv;
    memset(pInfo, 0, sizeof *pInfo);
    put_text(pInfo->label, sizeof pInfo->label, label);
    put_text(pInfo->manufacturerID, sizeof pInfo->manufacturerID, "WSurf");
    put_text(pInfo->model, sizeof pInfo->model, "WSurf Smart Card");
    put_text(pInfo->serialNumber, sizeof pInfo->serialNumber, "");
    put_text(pInfo->utcTime, sizeof pInfo->utcTime, "");
    pInfo->flags = CKF_WRITE_PROTECTED | CKF_LOGIN_REQUIRED | CKF_USER_PIN_INITIALIZED | CKF_TOKEN_INITIALIZED;
    pInfo->ulMaxSessionCount = CK_UNAVAILABLE_INFORMATION;
    pInfo->ulSessionCount = CK_UNAVAILABLE_INFORMATION;
    pInfo->ulMaxRwSessionCount = 0;
    pInfo->ulRwSessionCount = CK_UNAVAILABLE_INFORMATION;
    pInfo->ulMaxPinLen = maxPin;
    pInfo->ulMinPinLen = minPin;
    pInfo->ulTotalPublicMemory = CK_UNAVAILABLE_INFORMATION;
    pInfo->ulFreePublicMemory = CK_UNAVAILABLE_INFORMATION;
    pInfo->ulTotalPrivateMemory = CK_UNAVAILABLE_INFORMATION;
    pInfo->ulFreePrivateMemory = CK_UNAVAILABLE_INFORMATION;
    return CKR_OK;
}

CK_RV C_GetMechanismList(CK_SLOT_ID slotID, CK_MECHANISM_TYPE_PTR pMechanismList, CK_ULONG_PTR pulCount) {
    if (pulCount == NULL) return CKR_ARGUMENTS_BAD;
    return wsc_slot_mechanisms(slotID, pMechanismList, pulCount);
}

CK_RV C_GetMechanismInfo(CK_SLOT_ID slotID, CK_MECHANISM_TYPE type, CK_MECHANISM_INFO *pInfo) {
    if (pInfo == NULL) return CKR_ARGUMENTS_BAD;
    CK_MECHANISM_TYPE types[2];
    CK_ULONG count = 2;
    CK_RV rv = wsc_slot_mechanisms(slotID, types, &count);
    if (rv != CKR_OK) return rv;
    for (CK_ULONG i = 0; i < count; i++) {
        if (types[i] != type) continue;
        if (type == CKM_ECDSA) {
            *pInfo = (CK_MECHANISM_INFO){256, 384, CKF_HW | CKF_SIGN | CKF_EC_F_P | CKF_EC_NAMEDCURVE | CKF_EC_UNCOMPRESS};
        } else {
            *pInfo = (CK_MECHANISM_INFO){2048, 2048, CKF_HW | CKF_SIGN};
        }
        return CKR_OK;
    }
    return CKR_MECHANISM_INVALID;
}

CK_RV C_OpenSession(CK_SLOT_ID slotID, CK_FLAGS flags, CK_VOID_PTR pApplication, CK_NOTIFY Notify,
                    CK_SESSION_HANDLE_PTR phSession) {
    (void)pApplication;
    (void)Notify;
    if (phSession == NULL) return CKR_ARGUMENTS_BAD;
    if (!(flags & CKF_SERIAL_SESSION)) return CKR_SESSION_PARALLEL_NOT_SUPPORTED;
    if (flags & CKF_RW_SESSION) return CKR_TOKEN_WRITE_PROTECTED;
    return wsc_session_open(slotID, phSession);
}

CK_RV C_CloseSession(CK_SESSION_HANDLE hSession) { return wsc_session_close(hSession); }

CK_RV C_CloseAllSessions(CK_SLOT_ID slotID) { return wsc_session_close_all(slotID); }

CK_RV C_GetSessionInfo(CK_SESSION_HANDLE hSession, CK_SESSION_INFO *pInfo) {
    if (pInfo == NULL) return CKR_ARGUMENTS_BAD;
    CK_SLOT_ID slot;
    int loggedIn;
    CK_RV rv = wsc_session_info(hSession, &slot, &loggedIn);
    if (rv != CKR_OK) return rv;
    pInfo->slotID = slot;
    pInfo->state = loggedIn ? CKS_RO_USER_FUNCTIONS : CKS_RO_PUBLIC_SESSION;
    pInfo->flags = CKF_SERIAL_SESSION;
    pInfo->ulDeviceError = 0;
    return CKR_OK;
}

CK_RV C_Login(CK_SESSION_HANDLE hSession, CK_USER_TYPE userType, CK_UTF8CHAR_PTR pPin, CK_ULONG ulPinLen) {
    if (pPin == NULL) return CKR_ARGUMENTS_BAD;
    return wsc_login(hSession, userType, pPin, ulPinLen);
}

CK_RV C_Logout(CK_SESSION_HANDLE hSession) { return wsc_logout(hSession); }

CK_RV C_GetAttributeValue(CK_SESSION_HANDLE hSession, CK_OBJECT_HANDLE hObject, CK_ATTRIBUTE *pTemplate,
                          CK_ULONG ulCount) {
    if (pTemplate == NULL && ulCount != 0) return CKR_ARGUMENTS_BAD;
    CK_RV result = CKR_OK;
    for (CK_ULONG i = 0; i < ulCount; i++) {
        CK_ULONG length = pTemplate[i].ulValueLen;
        CK_RV rv = wsc_attribute(hSession, hObject, pTemplate[i].type, pTemplate[i].pValue, &length);
        if (rv == CKR_OK) {
            pTemplate[i].ulValueLen = length;
        } else if (rv == CKR_BUFFER_TOO_SMALL || rv == CKR_ATTRIBUTE_TYPE_INVALID) {
            // PKCS#11 §5.2: flag this attribute, keep filling the others, report the error last.
            pTemplate[i].ulValueLen = CK_UNAVAILABLE_INFORMATION;
            result = rv;
        } else {
            return rv;
        }
    }
    return result;
}

CK_RV C_FindObjectsInit(CK_SESSION_HANDLE hSession, CK_ATTRIBUTE *pTemplate, CK_ULONG ulCount) {
    if (pTemplate == NULL && ulCount != 0) return CKR_ARGUMENTS_BAD;
    CK_RV rv = wsc_find_init(hSession);
    if (rv != CKR_OK) return rv;
    for (CK_ULONG i = 0; i < ulCount; i++) {
        if (pTemplate[i].pValue == NULL && pTemplate[i].ulValueLen != 0) {
            wsc_find_final(hSession);
            return CKR_ARGUMENTS_BAD;
        }
        rv = wsc_find_filter(hSession, pTemplate[i].type, pTemplate[i].pValue, pTemplate[i].ulValueLen);
        if (rv != CKR_OK) {
            wsc_find_final(hSession);
            return rv;
        }
    }
    return CKR_OK;
}

CK_RV C_FindObjects(CK_SESSION_HANDLE hSession, CK_OBJECT_HANDLE_PTR phObject, CK_ULONG ulMaxObjectCount,
                    CK_ULONG_PTR pulObjectCount) {
    if (phObject == NULL || pulObjectCount == NULL) return CKR_ARGUMENTS_BAD;
    return wsc_find_next(hSession, ulMaxObjectCount, phObject, pulObjectCount);
}

CK_RV C_FindObjectsFinal(CK_SESSION_HANDLE hSession) { return wsc_find_final(hSession); }

CK_RV C_SignInit(CK_SESSION_HANDLE hSession, CK_MECHANISM *pMechanism, CK_OBJECT_HANDLE hKey) {
    if (pMechanism == NULL) return CKR_ARGUMENTS_BAD;
    return wsc_sign_init(hSession, pMechanism->mechanism, hKey);
}

CK_RV C_Sign(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pData, CK_ULONG ulDataLen, CK_BYTE_PTR pSignature,
             CK_ULONG_PTR pulSignatureLen) {
    if (pData == NULL || pulSignatureLen == NULL) return CKR_ARGUMENTS_BAD;
    return wsc_sign(hSession, pData, ulDataLen, pSignature, pulSignatureLen);
}

// Functions this read-only, sign-only module does not provide. PKCS#11 §5.1 defines
// CKR_FUNCTION_NOT_SUPPORTED for exactly this; the table slots must still be populated.
#define NOT_SUPPORTED(name, params) \
    static CK_RV name params { return CKR_FUNCTION_NOT_SUPPORTED; }

NOT_SUPPORTED(U_InitToken, (CK_SLOT_ID a, CK_UTF8CHAR_PTR b, CK_ULONG c, CK_UTF8CHAR_PTR d))
NOT_SUPPORTED(U_InitPIN, (CK_SESSION_HANDLE a, CK_UTF8CHAR_PTR b, CK_ULONG c))
NOT_SUPPORTED(U_SetPIN, (CK_SESSION_HANDLE a, CK_UTF8CHAR_PTR b, CK_ULONG c, CK_UTF8CHAR_PTR d, CK_ULONG e))
NOT_SUPPORTED(U_GetOperationState, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG_PTR c))
NOT_SUPPORTED(U_SetOperationState, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c, CK_OBJECT_HANDLE d, CK_OBJECT_HANDLE e))
NOT_SUPPORTED(U_CreateObject, (CK_SESSION_HANDLE a, CK_ATTRIBUTE *b, CK_ULONG c, CK_OBJECT_HANDLE_PTR d))
NOT_SUPPORTED(U_CopyObject, (CK_SESSION_HANDLE a, CK_OBJECT_HANDLE b, CK_ATTRIBUTE *c, CK_ULONG d, CK_OBJECT_HANDLE_PTR e))
NOT_SUPPORTED(U_DestroyObject, (CK_SESSION_HANDLE a, CK_OBJECT_HANDLE b))
NOT_SUPPORTED(U_GetObjectSize, (CK_SESSION_HANDLE a, CK_OBJECT_HANDLE b, CK_ULONG_PTR c))
NOT_SUPPORTED(U_SetAttributeValue, (CK_SESSION_HANDLE a, CK_OBJECT_HANDLE b, CK_ATTRIBUTE *c, CK_ULONG d))
NOT_SUPPORTED(U_EncryptInit, (CK_SESSION_HANDLE a, CK_MECHANISM *b, CK_OBJECT_HANDLE c))
NOT_SUPPORTED(U_Encrypt, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c, CK_BYTE_PTR d, CK_ULONG_PTR e))
NOT_SUPPORTED(U_EncryptUpdate, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c, CK_BYTE_PTR d, CK_ULONG_PTR e))
NOT_SUPPORTED(U_EncryptFinal, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG_PTR c))
NOT_SUPPORTED(U_DecryptInit, (CK_SESSION_HANDLE a, CK_MECHANISM *b, CK_OBJECT_HANDLE c))
NOT_SUPPORTED(U_Decrypt, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c, CK_BYTE_PTR d, CK_ULONG_PTR e))
NOT_SUPPORTED(U_DecryptUpdate, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c, CK_BYTE_PTR d, CK_ULONG_PTR e))
NOT_SUPPORTED(U_DecryptFinal, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG_PTR c))
NOT_SUPPORTED(U_DigestInit, (CK_SESSION_HANDLE a, CK_MECHANISM *b))
NOT_SUPPORTED(U_Digest, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c, CK_BYTE_PTR d, CK_ULONG_PTR e))
NOT_SUPPORTED(U_DigestUpdate, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c))
NOT_SUPPORTED(U_DigestKey, (CK_SESSION_HANDLE a, CK_OBJECT_HANDLE b))
NOT_SUPPORTED(U_DigestFinal, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG_PTR c))
NOT_SUPPORTED(U_SignUpdate, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c))
NOT_SUPPORTED(U_SignFinal, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG_PTR c))
NOT_SUPPORTED(U_SignRecoverInit, (CK_SESSION_HANDLE a, CK_MECHANISM *b, CK_OBJECT_HANDLE c))
NOT_SUPPORTED(U_SignRecover, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c, CK_BYTE_PTR d, CK_ULONG_PTR e))
NOT_SUPPORTED(U_VerifyInit, (CK_SESSION_HANDLE a, CK_MECHANISM *b, CK_OBJECT_HANDLE c))
NOT_SUPPORTED(U_Verify, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c, CK_BYTE_PTR d, CK_ULONG e))
NOT_SUPPORTED(U_VerifyUpdate, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c))
NOT_SUPPORTED(U_VerifyFinal, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c))
NOT_SUPPORTED(U_VerifyRecoverInit, (CK_SESSION_HANDLE a, CK_MECHANISM *b, CK_OBJECT_HANDLE c))
NOT_SUPPORTED(U_VerifyRecover, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c, CK_BYTE_PTR d, CK_ULONG_PTR e))
NOT_SUPPORTED(U_DigestEncryptUpdate, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c, CK_BYTE_PTR d, CK_ULONG_PTR e))
NOT_SUPPORTED(U_DecryptDigestUpdate, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c, CK_BYTE_PTR d, CK_ULONG_PTR e))
NOT_SUPPORTED(U_SignEncryptUpdate, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c, CK_BYTE_PTR d, CK_ULONG_PTR e))
NOT_SUPPORTED(U_DecryptVerifyUpdate, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c, CK_BYTE_PTR d, CK_ULONG_PTR e))
NOT_SUPPORTED(U_GenerateKey, (CK_SESSION_HANDLE a, CK_MECHANISM *b, CK_ATTRIBUTE *c, CK_ULONG d, CK_OBJECT_HANDLE_PTR e))
NOT_SUPPORTED(U_GenerateKeyPair, (CK_SESSION_HANDLE a, CK_MECHANISM *b, CK_ATTRIBUTE *c, CK_ULONG d, CK_ATTRIBUTE *e, CK_ULONG f, CK_OBJECT_HANDLE_PTR g, CK_OBJECT_HANDLE_PTR h))
NOT_SUPPORTED(U_WrapKey, (CK_SESSION_HANDLE a, CK_MECHANISM *b, CK_OBJECT_HANDLE c, CK_OBJECT_HANDLE d, CK_BYTE_PTR e, CK_ULONG_PTR f))
NOT_SUPPORTED(U_UnwrapKey, (CK_SESSION_HANDLE a, CK_MECHANISM *b, CK_OBJECT_HANDLE c, CK_BYTE_PTR d, CK_ULONG e, CK_ATTRIBUTE *f, CK_ULONG g, CK_OBJECT_HANDLE_PTR h))
NOT_SUPPORTED(U_DeriveKey, (CK_SESSION_HANDLE a, CK_MECHANISM *b, CK_OBJECT_HANDLE c, CK_ATTRIBUTE *d, CK_ULONG e, CK_OBJECT_HANDLE_PTR f))
NOT_SUPPORTED(U_SeedRandom, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c))
NOT_SUPPORTED(U_GenerateRandom, (CK_SESSION_HANDLE a, CK_BYTE_PTR b, CK_ULONG c))

static CK_RV U_GetFunctionStatus(CK_SESSION_HANDLE a) { (void)a; return CKR_FUNCTION_NOT_PARALLEL; }
static CK_RV U_CancelFunction(CK_SESSION_HANDLE a) { (void)a; return CKR_FUNCTION_NOT_PARALLEL; }

// Readers come and go without events; NSS and Firefox poll C_GetSlotList instead.
static CK_RV U_WaitForSlotEvent(CK_FLAGS flags, CK_SLOT_ID_PTR pSlot, CK_VOID_PTR pReserved) {
    (void)flags; (void)pSlot; (void)pReserved;
    return CKR_FUNCTION_NOT_SUPPORTED;
}

CK_FUNCTION_LIST wsurf_function_list = {
    {2, 40},
    C_Initialize, C_Finalize, C_GetInfo, C_GetFunctionList, C_GetSlotList, C_GetSlotInfo, C_GetTokenInfo,
    C_GetMechanismList, C_GetMechanismInfo, U_InitToken, U_InitPIN, U_SetPIN, C_OpenSession, C_CloseSession,
    C_CloseAllSessions, C_GetSessionInfo, U_GetOperationState, U_SetOperationState, C_Login, C_Logout,
    U_CreateObject, U_CopyObject, U_DestroyObject, U_GetObjectSize, C_GetAttributeValue, U_SetAttributeValue,
    C_FindObjectsInit, C_FindObjects, C_FindObjectsFinal, U_EncryptInit, U_Encrypt, U_EncryptUpdate,
    U_EncryptFinal, U_DecryptInit, U_Decrypt, U_DecryptUpdate, U_DecryptFinal, U_DigestInit, U_Digest,
    U_DigestUpdate, U_DigestKey, U_DigestFinal, C_SignInit, C_Sign, U_SignUpdate, U_SignFinal,
    U_SignRecoverInit, U_SignRecover, U_VerifyInit, U_Verify, U_VerifyUpdate, U_VerifyFinal,
    U_VerifyRecoverInit, U_VerifyRecover, U_DigestEncryptUpdate, U_DecryptDigestUpdate,
    U_SignEncryptUpdate, U_DecryptVerifyUpdate, U_GenerateKey, U_GenerateKeyPair, U_WrapKey, U_UnwrapKey,
    U_DeriveKey, U_SeedRandom, U_GenerateRandom, U_GetFunctionStatus, U_CancelFunction, U_WaitForSlotEvent,
};
