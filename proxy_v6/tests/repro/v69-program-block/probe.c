#include <winsock2.h>
#include <stdlib.h>
#include <string.h>

int wmain(int argc, wchar_t **argv) {
    WSADATA startup;
    struct sockaddr_in address;
    SOCKET sock;
    int port;
    int result;
    if (argc != 2) return 65;
    port = _wtoi(argv[1]);
    if (port < 1 || port > 65535) return 65;
    if (WSAStartup(MAKEWORD(2, 2), &startup) != 0) return 63;
    sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock == INVALID_SOCKET) return WSAGetLastError();
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons((u_short)port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    result = connect(sock, (struct sockaddr *)&address, sizeof(address));
    if (result == 0) {
        if (send(sock, "x", 1, 0) != 1) result = WSAGetLastError();
    } else {
        result = WSAGetLastError();
    }
    closesocket(sock);
    WSACleanup();
    return result;
}
