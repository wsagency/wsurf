#include <stdint.h>

typedef int32_t SCARDCONTEXT;
typedef int32_t SCARDHANDLE;
typedef struct { uint32_t dwProtocol; uint32_t cbPciLength; } SCARD_IO_REQUEST;

int32_t SCardEstablishContext(uint32_t dwScope, const void *pvReserved1, const void *pvReserved2, SCARDCONTEXT *phContext);
int32_t SCardReleaseContext(SCARDCONTEXT hContext);
int32_t SCardListReaders(SCARDCONTEXT hContext, const char *mszGroups, char *mszReaders, uint32_t *pcchReaders);
int32_t SCardConnect(SCARDCONTEXT hContext, const char *szReader, uint32_t dwShareMode, uint32_t dwPreferredProtocols, SCARDHANDLE *phCard, uint32_t *pdwActiveProtocol);
int32_t SCardDisconnect(SCARDHANDLE hCard, uint32_t dwDisposition);
int32_t SCardStatus(SCARDHANDLE hCard, char *mszReaderNames, uint32_t *pcchReaderLen, uint32_t *pdwState, uint32_t *pdwProtocol, unsigned char *pbAtr, uint32_t *pcbAtrLen);
int32_t SCardTransmit(SCARDHANDLE hCard, const SCARD_IO_REQUEST *pioSendPci, const unsigned char *pbSendBuffer, uint32_t cbSendLength, SCARD_IO_REQUEST *pioRecvPci, unsigned char *pbRecvBuffer, uint32_t *pcbRecvLength);
