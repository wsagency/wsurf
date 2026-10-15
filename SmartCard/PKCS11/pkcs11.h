// PKCS#11 v2.40 (OASIS) types and constants used by this module. Natural alignment, no
// packing pragmas: the Cryptoki 1-byte convention is Windows-only; the canonical header
// leaves UNIX at natural alignment, and on arm64 the linker rejects pointer atoms in
// 1-byte-packed structs (the function list is defined outside the packed region upstream).
#ifndef WSURF_PKCS11_H
#define WSURF_PKCS11_H

#include <stddef.h>

typedef unsigned char CK_BYTE;
typedef unsigned char CK_UTF8CHAR;
typedef unsigned char CK_BBOOL;
typedef unsigned long CK_ULONG;
typedef unsigned long CK_FLAGS;
typedef unsigned long CK_RV;
typedef unsigned long CK_SLOT_ID;
typedef unsigned long CK_SESSION_HANDLE;
typedef unsigned long CK_OBJECT_HANDLE;
typedef unsigned long CK_USER_TYPE;
typedef unsigned long CK_STATE;
typedef unsigned long CK_ATTRIBUTE_TYPE;
typedef unsigned long CK_MECHANISM_TYPE;
typedef unsigned long CK_NOTIFICATION;
typedef void *CK_VOID_PTR;
typedef CK_BYTE *CK_BYTE_PTR;
typedef CK_UTF8CHAR *CK_UTF8CHAR_PTR;
typedef CK_ULONG *CK_ULONG_PTR;
typedef CK_SLOT_ID *CK_SLOT_ID_PTR;
typedef CK_SESSION_HANDLE *CK_SESSION_HANDLE_PTR;
typedef CK_OBJECT_HANDLE *CK_OBJECT_HANDLE_PTR;
typedef CK_MECHANISM_TYPE *CK_MECHANISM_TYPE_PTR;

typedef struct CK_VERSION {
    CK_BYTE major;
    CK_BYTE minor;
} CK_VERSION;

typedef struct CK_INFO {
    CK_VERSION cryptokiVersion;
    CK_UTF8CHAR manufacturerID[32];
    CK_FLAGS flags;
    CK_UTF8CHAR libraryDescription[32];
    CK_VERSION libraryVersion;
} CK_INFO;

typedef struct CK_SLOT_INFO {
    CK_UTF8CHAR slotDescription[64];
    CK_UTF8CHAR manufacturerID[32];
    CK_FLAGS flags;
    CK_VERSION hardwareVersion;
    CK_VERSION firmwareVersion;
} CK_SLOT_INFO;

typedef struct CK_TOKEN_INFO {
    CK_UTF8CHAR label[32];
    CK_UTF8CHAR manufacturerID[32];
    CK_UTF8CHAR model[16];
    CK_UTF8CHAR serialNumber[16];
    CK_FLAGS flags;
    CK_ULONG ulMaxSessionCount;
    CK_ULONG ulSessionCount;
    CK_ULONG ulMaxRwSessionCount;
    CK_ULONG ulRwSessionCount;
    CK_ULONG ulMaxPinLen;
    CK_ULONG ulMinPinLen;
    CK_ULONG ulTotalPublicMemory;
    CK_ULONG ulFreePublicMemory;
    CK_ULONG ulTotalPrivateMemory;
    CK_ULONG ulFreePrivateMemory;
    CK_VERSION hardwareVersion;
    CK_VERSION firmwareVersion;
    CK_UTF8CHAR utcTime[16];
} CK_TOKEN_INFO;

typedef struct CK_SESSION_INFO {
    CK_SLOT_ID slotID;
    CK_STATE state;
    CK_FLAGS flags;
    CK_ULONG ulDeviceError;
} CK_SESSION_INFO;

typedef struct CK_ATTRIBUTE {
    CK_ATTRIBUTE_TYPE type;
    CK_VOID_PTR pValue;
    CK_ULONG ulValueLen;
} CK_ATTRIBUTE;

typedef struct CK_MECHANISM {
    CK_MECHANISM_TYPE mechanism;
    CK_VOID_PTR pParameter;
    CK_ULONG ulParameterLen;
} CK_MECHANISM;

typedef struct CK_MECHANISM_INFO {
    CK_ULONG ulMinKeySize;
    CK_ULONG ulMaxKeySize;
    CK_FLAGS flags;
} CK_MECHANISM_INFO;

typedef struct CK_C_INITIALIZE_ARGS {
    CK_RV (*CreateMutex)(CK_VOID_PTR *ppMutex);
    CK_RV (*DestroyMutex)(CK_VOID_PTR pMutex);
    CK_RV (*LockMutex)(CK_VOID_PTR pMutex);
    CK_RV (*UnlockMutex)(CK_VOID_PTR pMutex);
    CK_FLAGS flags;
    CK_VOID_PTR pReserved;
} CK_C_INITIALIZE_ARGS;

typedef CK_RV (*CK_NOTIFY)(CK_SESSION_HANDLE hSession, CK_NOTIFICATION event, CK_VOID_PTR pApplication);

typedef struct CK_FUNCTION_LIST {
    CK_VERSION version;
    CK_RV (*C_Initialize)(CK_VOID_PTR pInitArgs);
    CK_RV (*C_Finalize)(CK_VOID_PTR pReserved);
    CK_RV (*C_GetInfo)(CK_INFO *pInfo);
    CK_RV (*C_GetFunctionList)(struct CK_FUNCTION_LIST **ppFunctionList);
    CK_RV (*C_GetSlotList)(CK_BBOOL tokenPresent, CK_SLOT_ID_PTR pSlotList, CK_ULONG_PTR pulCount);
    CK_RV (*C_GetSlotInfo)(CK_SLOT_ID slotID, CK_SLOT_INFO *pInfo);
    CK_RV (*C_GetTokenInfo)(CK_SLOT_ID slotID, CK_TOKEN_INFO *pInfo);
    CK_RV (*C_GetMechanismList)(CK_SLOT_ID slotID, CK_MECHANISM_TYPE_PTR pMechanismList, CK_ULONG_PTR pulCount);
    CK_RV (*C_GetMechanismInfo)(CK_SLOT_ID slotID, CK_MECHANISM_TYPE type, CK_MECHANISM_INFO *pInfo);
    CK_RV (*C_InitToken)(CK_SLOT_ID slotID, CK_UTF8CHAR_PTR pPin, CK_ULONG ulPinLen, CK_UTF8CHAR_PTR pLabel);
    CK_RV (*C_InitPIN)(CK_SESSION_HANDLE hSession, CK_UTF8CHAR_PTR pPin, CK_ULONG ulPinLen);
    CK_RV (*C_SetPIN)(CK_SESSION_HANDLE hSession, CK_UTF8CHAR_PTR pOldPin, CK_ULONG ulOldLen, CK_UTF8CHAR_PTR pNewPin, CK_ULONG ulNewLen);
    CK_RV (*C_OpenSession)(CK_SLOT_ID slotID, CK_FLAGS flags, CK_VOID_PTR pApplication, CK_NOTIFY Notify, CK_SESSION_HANDLE_PTR phSession);
    CK_RV (*C_CloseSession)(CK_SESSION_HANDLE hSession);
    CK_RV (*C_CloseAllSessions)(CK_SLOT_ID slotID);
    CK_RV (*C_GetSessionInfo)(CK_SESSION_HANDLE hSession, CK_SESSION_INFO *pInfo);
    CK_RV (*C_GetOperationState)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pOperationState, CK_ULONG_PTR pulOperationStateLen);
    CK_RV (*C_SetOperationState)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pOperationState, CK_ULONG ulOperationStateLen, CK_OBJECT_HANDLE hEncryptionKey, CK_OBJECT_HANDLE hAuthenticationKey);
    CK_RV (*C_Login)(CK_SESSION_HANDLE hSession, CK_USER_TYPE userType, CK_UTF8CHAR_PTR pPin, CK_ULONG ulPinLen);
    CK_RV (*C_Logout)(CK_SESSION_HANDLE hSession);
    CK_RV (*C_CreateObject)(CK_SESSION_HANDLE hSession, CK_ATTRIBUTE *pTemplate, CK_ULONG ulCount, CK_OBJECT_HANDLE_PTR phObject);
    CK_RV (*C_CopyObject)(CK_SESSION_HANDLE hSession, CK_OBJECT_HANDLE hObject, CK_ATTRIBUTE *pTemplate, CK_ULONG ulCount, CK_OBJECT_HANDLE_PTR phNewObject);
    CK_RV (*C_DestroyObject)(CK_SESSION_HANDLE hSession, CK_OBJECT_HANDLE hObject);
    CK_RV (*C_GetObjectSize)(CK_SESSION_HANDLE hSession, CK_OBJECT_HANDLE hObject, CK_ULONG_PTR pulSize);
    CK_RV (*C_GetAttributeValue)(CK_SESSION_HANDLE hSession, CK_OBJECT_HANDLE hObject, CK_ATTRIBUTE *pTemplate, CK_ULONG ulCount);
    CK_RV (*C_SetAttributeValue)(CK_SESSION_HANDLE hSession, CK_OBJECT_HANDLE hObject, CK_ATTRIBUTE *pTemplate, CK_ULONG ulCount);
    CK_RV (*C_FindObjectsInit)(CK_SESSION_HANDLE hSession, CK_ATTRIBUTE *pTemplate, CK_ULONG ulCount);
    CK_RV (*C_FindObjects)(CK_SESSION_HANDLE hSession, CK_OBJECT_HANDLE_PTR phObject, CK_ULONG ulMaxObjectCount, CK_ULONG_PTR pulObjectCount);
    CK_RV (*C_FindObjectsFinal)(CK_SESSION_HANDLE hSession);
    CK_RV (*C_EncryptInit)(CK_SESSION_HANDLE hSession, CK_MECHANISM *pMechanism, CK_OBJECT_HANDLE hKey);
    CK_RV (*C_Encrypt)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pData, CK_ULONG ulDataLen, CK_BYTE_PTR pEncryptedData, CK_ULONG_PTR pulEncryptedDataLen);
    CK_RV (*C_EncryptUpdate)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pPart, CK_ULONG ulPartLen, CK_BYTE_PTR pEncryptedPart, CK_ULONG_PTR pulEncryptedPartLen);
    CK_RV (*C_EncryptFinal)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pLastEncryptedPart, CK_ULONG_PTR pulLastEncryptedPartLen);
    CK_RV (*C_DecryptInit)(CK_SESSION_HANDLE hSession, CK_MECHANISM *pMechanism, CK_OBJECT_HANDLE hKey);
    CK_RV (*C_Decrypt)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pEncryptedData, CK_ULONG ulEncryptedDataLen, CK_BYTE_PTR pData, CK_ULONG_PTR pulDataLen);
    CK_RV (*C_DecryptUpdate)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pEncryptedPart, CK_ULONG ulEncryptedPartLen, CK_BYTE_PTR pPart, CK_ULONG_PTR pulPartLen);
    CK_RV (*C_DecryptFinal)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pLastPart, CK_ULONG_PTR pulLastPartLen);
    CK_RV (*C_DigestInit)(CK_SESSION_HANDLE hSession, CK_MECHANISM *pMechanism);
    CK_RV (*C_Digest)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pData, CK_ULONG ulDataLen, CK_BYTE_PTR pDigest, CK_ULONG_PTR pulDigestLen);
    CK_RV (*C_DigestUpdate)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pPart, CK_ULONG ulPartLen);
    CK_RV (*C_DigestKey)(CK_SESSION_HANDLE hSession, CK_OBJECT_HANDLE hKey);
    CK_RV (*C_DigestFinal)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pDigest, CK_ULONG_PTR pulDigestLen);
    CK_RV (*C_SignInit)(CK_SESSION_HANDLE hSession, CK_MECHANISM *pMechanism, CK_OBJECT_HANDLE hKey);
    CK_RV (*C_Sign)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pData, CK_ULONG ulDataLen, CK_BYTE_PTR pSignature, CK_ULONG_PTR pulSignatureLen);
    CK_RV (*C_SignUpdate)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pPart, CK_ULONG ulPartLen);
    CK_RV (*C_SignFinal)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pSignature, CK_ULONG_PTR pulSignatureLen);
    CK_RV (*C_SignRecoverInit)(CK_SESSION_HANDLE hSession, CK_MECHANISM *pMechanism, CK_OBJECT_HANDLE hKey);
    CK_RV (*C_SignRecover)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pData, CK_ULONG ulDataLen, CK_BYTE_PTR pSignature, CK_ULONG_PTR pulSignatureLen);
    CK_RV (*C_VerifyInit)(CK_SESSION_HANDLE hSession, CK_MECHANISM *pMechanism, CK_OBJECT_HANDLE hKey);
    CK_RV (*C_Verify)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pData, CK_ULONG ulDataLen, CK_BYTE_PTR pSignature, CK_ULONG ulSignatureLen);
    CK_RV (*C_VerifyUpdate)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pPart, CK_ULONG ulPartLen);
    CK_RV (*C_VerifyFinal)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pSignature, CK_ULONG ulSignatureLen);
    CK_RV (*C_VerifyRecoverInit)(CK_SESSION_HANDLE hSession, CK_MECHANISM *pMechanism, CK_OBJECT_HANDLE hKey);
    CK_RV (*C_VerifyRecover)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pSignature, CK_ULONG ulSignatureLen, CK_BYTE_PTR pData, CK_ULONG_PTR pulDataLen);
    CK_RV (*C_DigestEncryptUpdate)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pPart, CK_ULONG ulPartLen, CK_BYTE_PTR pEncryptedPart, CK_ULONG_PTR pulEncryptedPartLen);
    CK_RV (*C_DecryptDigestUpdate)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pEncryptedPart, CK_ULONG ulEncryptedPartLen, CK_BYTE_PTR pPart, CK_ULONG_PTR pulPartLen);
    CK_RV (*C_SignEncryptUpdate)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pPart, CK_ULONG ulPartLen, CK_BYTE_PTR pEncryptedPart, CK_ULONG_PTR pulEncryptedPartLen);
    CK_RV (*C_DecryptVerifyUpdate)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pEncryptedPart, CK_ULONG ulEncryptedPartLen, CK_BYTE_PTR pPart, CK_ULONG_PTR pulPartLen);
    CK_RV (*C_GenerateKey)(CK_SESSION_HANDLE hSession, CK_MECHANISM *pMechanism, CK_ATTRIBUTE *pTemplate, CK_ULONG ulCount, CK_OBJECT_HANDLE_PTR phKey);
    CK_RV (*C_GenerateKeyPair)(CK_SESSION_HANDLE hSession, CK_MECHANISM *pMechanism, CK_ATTRIBUTE *pPublicKeyTemplate, CK_ULONG ulPublicKeyAttributeCount, CK_ATTRIBUTE *pPrivateKeyTemplate, CK_ULONG ulPrivateKeyAttributeCount, CK_OBJECT_HANDLE_PTR phPublicKey, CK_OBJECT_HANDLE_PTR phPrivateKey);
    CK_RV (*C_WrapKey)(CK_SESSION_HANDLE hSession, CK_MECHANISM *pMechanism, CK_OBJECT_HANDLE hWrappingKey, CK_OBJECT_HANDLE hKey, CK_BYTE_PTR pWrappedKey, CK_ULONG_PTR pulWrappedKeyLen);
    CK_RV (*C_UnwrapKey)(CK_SESSION_HANDLE hSession, CK_MECHANISM *pMechanism, CK_OBJECT_HANDLE hUnwrappingKey, CK_BYTE_PTR pWrappedKey, CK_ULONG ulWrappedKeyLen, CK_ATTRIBUTE *pTemplate, CK_ULONG ulAttributeCount, CK_OBJECT_HANDLE_PTR phKey);
    CK_RV (*C_DeriveKey)(CK_SESSION_HANDLE hSession, CK_MECHANISM *pMechanism, CK_OBJECT_HANDLE hBaseKey, CK_ATTRIBUTE *pTemplate, CK_ULONG ulAttributeCount, CK_OBJECT_HANDLE_PTR phKey);
    CK_RV (*C_SeedRandom)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pSeed, CK_ULONG ulSeedLen);
    CK_RV (*C_GenerateRandom)(CK_SESSION_HANDLE hSession, CK_BYTE_PTR pRandomData, CK_ULONG ulRandomLen);
    CK_RV (*C_GetFunctionStatus)(CK_SESSION_HANDLE hSession);
    CK_RV (*C_CancelFunction)(CK_SESSION_HANDLE hSession);
    CK_RV (*C_WaitForSlotEvent)(CK_FLAGS flags, CK_SLOT_ID_PTR pSlot, CK_VOID_PTR pReserved);
} CK_FUNCTION_LIST;

#define CK_UNAVAILABLE_INFORMATION (~0UL)

#define CKR_OK 0x00UL
#define CKR_SLOT_ID_INVALID 0x03UL
#define CKR_GENERAL_ERROR 0x05UL
#define CKR_ARGUMENTS_BAD 0x07UL
#define CKR_NO_EVENT 0x08UL
#define CKR_CANT_LOCK 0x0AUL
#define CKR_ATTRIBUTE_TYPE_INVALID 0x12UL
#define CKR_FUNCTION_NOT_PARALLEL 0x51UL
#define CKR_FUNCTION_NOT_SUPPORTED 0x54UL
#define CKR_MECHANISM_INVALID 0x70UL
#define CKR_SESSION_PARALLEL_NOT_SUPPORTED 0xB4UL
#define CKR_TOKEN_WRITE_PROTECTED 0xE2UL
#define CKR_BUFFER_TOO_SMALL 0x150UL
#define CKR_CRYPTOKI_NOT_INITIALIZED 0x190UL
#define CKR_CRYPTOKI_ALREADY_INITIALIZED 0x191UL

#define CKF_TOKEN_PRESENT 0x01UL
#define CKF_REMOVABLE_DEVICE 0x02UL
#define CKF_HW_SLOT 0x04UL
#define CKF_WRITE_PROTECTED 0x02UL
#define CKF_LOGIN_REQUIRED 0x04UL
#define CKF_USER_PIN_INITIALIZED 0x08UL
#define CKF_TOKEN_INITIALIZED 0x400UL
#define CKF_RW_SESSION 0x02UL
#define CKF_SERIAL_SESSION 0x04UL
#define CKF_OS_LOCKING_OK 0x02UL
#define CKF_HW 0x01UL
#define CKF_SIGN 0x800UL
#define CKF_EC_F_P 0x00100000UL
#define CKF_EC_NAMEDCURVE 0x00800000UL
#define CKF_EC_UNCOMPRESS 0x01000000UL

#define CKS_RO_PUBLIC_SESSION 0UL
#define CKS_RO_USER_FUNCTIONS 1UL

#define CKM_SHA256_RSA_PKCS 0x40UL
#define CKM_ECDSA 0x1041UL

#endif
