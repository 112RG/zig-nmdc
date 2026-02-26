#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <errno.h>
#include <sys/select.h>

// lock_to_key function - converts NMDC lock to key
char *lock_to_key(const char *lock)
{
    int len = strlen(lock);
    unsigned char *key = malloc(len);
    int len2 = 0;
    int i;

    // Step 1: XOR operations
    for(i = 1; i < len; i++)
        key[i] = lock[i] ^ lock[i-1];
    key[0] = lock[0] ^ lock[len-1] ^ lock[len-2] ^ 5;

    // Step 2: Nibble swap
    for(i = 0; i < len; i++)
    {
        key[i] = ((key[i]<<4) & 0xF0) | ((key[i]>>4) & 0x0F);
    }

    // Step 3: Calculate output length
    for(i = 0; i < len; i++)
    {
        switch(key[i])
        {
        case 0:
        case 5:
        case 36:
        case 96:
        case 124:
        case 126:
            len2+=10;
            break;
        default:
            len2++;
        }
    }

    // Step 4: Build output
    char *newkey = malloc(len2 + 1);
    char *newkey_p = newkey;
    for(i = 0; i < len; i++)
    {
        switch(key[i])
        {
        case 0:
            sprintf(newkey_p, "/%%DCN000%%/");
            newkey_p += 10;
            break;
        case 5:
            sprintf(newkey_p, "/%%DCN005%%/");
            newkey_p += 10;
            break;
        case 36:
            sprintf(newkey_p, "/%%DCN036%%/");
            newkey_p += 10;
            break;
        case 96:
            sprintf(newkey_p, "/%%DCN096%%/");
            newkey_p += 10;
            break;
        case 124:
            sprintf(newkey_p, "/%%DCN124%%/");
            newkey_p += 10;
            break;
        case 126:
            sprintf(newkey_p, "/%%DCN126%%/");
            newkey_p += 10;
            break;
        default:
            *newkey_p = key[i];
            newkey_p++;
        }
    }
    *newkey_p = '\0';
    free(key);
    return newkey;
}

// Socket helper
int connect_to_hub(const char *host, int port) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return -1;

    // Set timeout
    struct timeval tv = {5, 0};
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct hostent *server = gethostbyname(host);
    if (!server) return -1;

    struct sockaddr_in serv_addr = {0};
    serv_addr.sin_family = AF_INET;
    memcpy(&serv_addr.sin_addr.s_addr, server->h_addr, server->h_length);
    serv_addr.sin_port = htons(port);

    if (connect(sock, (struct sockaddr *)&serv_addr, sizeof(serv_addr)) < 0) {
        close(sock);
        return -1;
    }
    return sock;
}

// Read until delimiter or timeout
int read_line(int sock, char *buffer, int maxlen, int timeout_sec) {
    int pos = 0;
    char c;
    
    while (pos < maxlen - 1) {
        fd_set readfds;
        struct timeval tv = {timeout_sec, 0};
        FD_ZERO(&readfds);
        FD_SET(sock, &readfds);
        
        int ret = select(sock + 1, &readfds, NULL, NULL, &tv);
        if (ret <= 0) break;
        
        int n = recv(sock, &c, 1, 0);
        if (n <= 0) break;
        
        if (c == '|') {
            buffer[pos++] = '|';
            break;
        }
        buffer[pos++] = c;
    }
    buffer[pos] = '\0';
    return pos;
}

// Parse lock from $Lock message
char *parse_lock(const char *input) {
    const char *lock_start = strstr(input, "$Lock ");
    if (!lock_start) return NULL;
    
    lock_start += 6;
    const char *lock_end = strchr(lock_start, ' ');
    if (!lock_end) return NULL;
    
    int lock_len = lock_end - lock_start;
    char *lock = malloc(lock_len + 1);
    strncpy(lock, lock_start, lock_len);
    lock[lock_len] = '\0';
    
    return lock;
}

int main() {
    const char *host = "10.0.1.141";
    int port = 411;
    const char *nick = "TestBot";
    
    printf("=== NMDC Client ===\n");
    printf("Connecting to %s:%d...\n", host, port);
    
    int sock = connect_to_hub(host, port);
    if (sock < 0) {
        perror("connect");
        return 1;
    }
    printf("Connected!\n");
    
    // Read lock
    char buffer[4096] = {0};
    int len = read_line(sock, buffer, sizeof(buffer), 5);
    printf("RX: %s\n", buffer);
    
    if (strncmp(buffer, "$Lock ", 6) != 0) {
        fprintf(stderr, "Expected $Lock, got: %s\n", buffer);
        close(sock);
        return 1;
    }
    
    // Parse lock
    char *lock = parse_lock(buffer);
    printf("Lock: %s\n", lock);
    
    // IMPORTANT: If lock starts with EXTENDEDPROTOCOL, send $Supports first
    int is_extended = (strncmp(lock, "EXTENDEDPROTOCOL", 16) == 0);
    if (is_extended) {
        printf("EXTENDED lock detected - sending $Supports\n");
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "$Supports UserCommand NoGetINFO TTHSearch ZPipe0|");
        send(sock, cmd, strlen(cmd), 0);
        printf("TX: $Supports ... (sent)\n");
        fflush(stdout);
        
        // Read hub's $Supports response
        memset(buffer, 0, sizeof(buffer));
        len = read_line(sock, buffer, sizeof(buffer), 5);
        printf("After $Supports, RX: %s\n", buffer);
        fflush(stdout);
    }
    
    // Generate key
    char *key = lock_to_key(lock);
    printf("Key generated (len=%zu)\n", strlen(key));
    
    // Send $Key
    char cmd[4096];
    snprintf(cmd, sizeof(cmd), "$Key %s|", key);
    printf("TX: $Key ... (len=%zu)\n", strlen(cmd));
    fflush(stdout);
    send(sock, cmd, strlen(cmd), 0);
    printf("Key sent, waiting for response...\n");
    fflush(stdout);
    usleep(500000);
    
    // Read $Supports response after key (for extended protocol)
    if (is_extended) {
        printf("Reading response after key...\n");
        fflush(stdout);
        memset(buffer, 0, sizeof(buffer));
        len = read_line(sock, buffer, sizeof(buffer), 5);
        printf("After $Key, RX: %s\n", buffer);
        fflush(stdout);
    }
    
    // Send $ValidateNick
    snprintf(cmd, sizeof(cmd), "$ValidateNick %s|", nick);
    printf("TX: $ValidateNick %s\n", nick);
    send(sock, cmd, strlen(cmd), 0);
    usleep(500000);
    
    // Read $Hello
    memset(buffer, 0, sizeof(buffer));
    len = read_line(sock, buffer, sizeof(buffer));
    if (len > 0) printf("RX: %s\n", buffer);
    
    if (strncmp(buffer, "$Hello", 6) != 0) {
        printf("Warning: Expected $Hello\n");
    } else {
        printf("Successfully logged in as %s!\n", nick);
    }
    
    // Send $MyINFO
    snprintf(cmd, sizeof(cmd), 
        "$MyINFO $ALL %s Test Bot$ $Cable$1$test@test.com$0|", nick);
    printf("TX: $MyINFO [info]\n");
    send(sock, cmd, strlen(cmd), 0);
    usleep(200000);
    
    // Send $GetNickList
    snprintf(cmd, sizeof(cmd), "$GetNickList|");
    printf("TX: $GetNickList\n");
    send(sock, cmd, strlen(cmd), 0);
    usleep(500000);
    
    // Read nick list
    memset(buffer, 0, sizeof(buffer));
    len = read_line(sock, buffer, sizeof(buffer));
    if (len > 0) printf("RX: %s\n", buffer);
    
    // Send chat message - $MainChat
    snprintf(cmd, sizeof(cmd), "$MainChat <%s> successfully connected|", nick);
    printf("TX: $MainChat <%s> successfully connected\n", nick);
    send(sock, cmd, strlen(cmd), 0);
    
    printf("\n=== Chat message sent successfully! ===\n");
    
    // Wait a moment for any responses
    sleep(1);
    
    // Read any final messages
    for (int i = 0; i < 3; i++) {
        memset(buffer, 0, sizeof(buffer));
        len = read_line(sock, buffer, sizeof(buffer), 5);
        if (len > 0) printf("RX: %s\n", buffer);
        else break;
    }
    
    // Quit gracefully
    snprintf(cmd, sizeof(cmd), "$Quit|");
    send(sock, cmd, strlen(cmd), 0);
    
    close(sock);
    free(lock);
    free(key);
    
    printf("Disconnected.\n");
    return 0;
}
