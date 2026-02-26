# NMDC Protocol Skill

## Overview
NMDC (Neo-Modus Direct Connect) is a text protocol for client-server networking in Direct Connect file-sharing networks. This skill provides comprehensive guidance for implementing NMDC client-server communications in C.

## Protocol Basics

### Message Structure
- Most messages begin with `$` (dollar sign)
- Most messages end with `|` (pipe)
- Command format: `$CommandName param1 param2|`
- Chat messages use format: `<nick> message|`

### Default Ports
- Hub port: 411 (then try 412, 413, etc.)
- Client port: 412

## $Lock/$Key Handshake

The $Lock/$Key exchange is required for both client-hub and client-client connections.

### Lock/Key Algorithm (from NMDC spec)

```c
// Generate key from lock string
char *lock_to_key(const char *lock) {
    int len = strlen(lock);
    char *key = malloc(len);
    int len2 = 0;
    
    // Step 1: XOR operations
    for (int i = 1; i < len; i++) {
        key[i] = lock[i] ^ lock[i-1];
    }
    key[0] = lock[0] ^ lock[len-1] ^ lock[len-2] ^ 5;
    
    // Step 2: Nibble swap
    for (int i = 0; i < len; i++) {
        key[i] = ((key[i] << 4) & 0xF0) | ((key[i] >> 4) & 0x0F);
    }
    
    // Step 3: Calculate output length (escape special chars)
    for (int i = 0; i < len; i++) {
        switch ((unsigned char)key[i]) {
            case 0: case 5: case 36: case 96: case 124: case 126:
                len2 += 10;  // /%DCNXXX%/ takes 10 chars
                break;
            default:
                len2++;
        }
    }
    
    // Step 4: Build output with escape sequences
    char *newkey = malloc(len2 + 1);
    char *p = newkey;
    for (int i = 0; i < len; i++) {
        switch ((unsigned char)key[i]) {
            case 0:
                sprintf(p, "/%%DCN000%%/");
                p += 10;
                break;
            case 5:
                sprintf(p, "/%%DCN005%%/");
                p += 10;
                break;
            case 36:
                sprintf(p, "/%%DCN036%%/");
                p += 10;
                break;
            case 96:
                sprintf(p, "/%%DCN096%%/");
                p += 10;
                break;
            case 124:
                sprintf(p, "/%%DCN124%%/");
                p += 10;
                break;
            case 126:
                sprintf(p, "/%%DCN126%%/");
                p += 10;
                break;
            default:
                *p++ = key[i];
        }
    }
    *p = '\0';
    free(key);
    return newkey;
}
```

## Client-Hub Connection Flow

1. **Connect to hub** (TCP socket)
2. **Receive $Lock** - Hub sends lock string
   ```
   $Lock EXTENDEDPROTOCOLABCABCABCABCABCABC Pk=PtokaX|
   ```
3. **Parse lock** - Extract everything between "$Lock " and " Pk="
4. **Generate key** - Use lock_to_key() algorithm
5. **Send $Key** - Send generated key
   ```
   $Key <generated_key>|
   ```
6. **Read hub response** - May receive:
   - `$ValidateNick <nick>|` - Nick validation needed
   - `$Hello <nick>|` - Login successful
   - `$GetPass|` - Password required

7. **Send $MyNick** (if validated)
   ```
   $MyNick <nick>|
   ```

8. **Send $Version** (optional)
   ```
   $Version 1,0091|
   ```

9. **Send $Supports** (optional, for extensions)
   ```
   $Supports UserCommand NoGetINFO TTHSearch ZPipe0|
   ```

10. **Send $MyINFO** - User info
    ```
    $MyINFO $ALL nick description$ connection$flag$email$share_size|
    ```

11. **Request nick list**
    ```
    $GetNickList|
    ```

## Common Commands

### Chat
- **Public**: `<nick> message|`
- **Private**: `$To: target From: sender $<sender> message|`

### Sending Messages
```
$Say <nick> message|         // NMDC 1.0091+
$MainChat <nick> message|   // Older clients
```

### User Info
```
$GetINFO other_nick sender_nick|
$MyINFO $ALL nick desc$ conn$flag$email$size|
```

### Quit
```
$Quit nick|
```

## Escape Sequences

Special characters must be escaped in chat messages:

| Character | Decimal | Escape Sequence |
|-----------|---------|-----------------|
| $         | 36      | &#36; or /%DCN036%/ |
| |         | 124     | &#124; or /%DCN124%/ |
| &         | 38      | &amp; |
| `         | 96      | /%DCN096%/ |
| ~         | 126     | /%DCN126%/ |

## Example: Full Login Sequence

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

// lock_to_key function (see above)

// Read until delimiter
int read_until(int sock, char *buf, int maxlen, char delim) {
    int pos = 0;
    char c;
    while (pos < maxlen - 1) {
        int n = recv(sock, &c, 1, 0);
        if (n <= 0) break;
        if (c == delim) {
            buf[pos++] = c;
            break;
        }
        buf[pos++] = c;
    }
    buf[pos] = '\0';
    return pos;
}

// Parse lock from $Lock message
char *parse_lock(const char *msg) {
    const char *start = strstr(msg, "$Lock ");
    if (!start) return NULL;
    start += 6;
    const char *end = strchr(start, ' ');
    if (!end) return NULL;
    int len = end - start;
    char *lock = malloc(len + 1);
    strncpy(lock, start, len);
    lock[len] = '\0';
    return lock;
}

int main() {
    const char *host = "10.0.1.141";
    int port = 411;
    const char *nick = "TestBot";
    
    // Connect
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, host, &addr.sin_addr);
    connect(sock, (struct sockaddr *)&addr, sizeof(addr));
    
    // Read lock
    char buffer[4096] = {0};
    read_until(sock, buffer, sizeof(buffer), '|');
    printf("Received: %s\n", buffer);
    
    // Parse lock and generate key
    char *lock = parse_lock(buffer);
    char *key = lock_to_key(lock);
    
    // Send key
    char cmd[4096];
    snprintf(cmd, sizeof(cmd), "$Key %s|", key);
    send(sock, cmd, strlen(cmd), 0);
    printf("Sent: %s\n", cmd);
    
    // Read responses
    while (1) {
        memset(buffer, 0, sizeof(buffer));
        int len = read_until(sock, buffer, sizeof(buffer), '|');
        if (len <= 0) break;
        printf("Received: %s\n", buffer);
        
        if (strncmp(buffer, "$ValidateNick", 13) == 0) {
            snprintf(cmd, sizeof(cmd), "$MyNick %s|", nick);
            send(sock, cmd, strlen(cmd), 0);
        }
        else if (strncmp(buffer, "$Hello", 6) == 0) {
            printf("Logged in as: %s\n", nick);
            break;
        }
    }
    
    // Send MyINFO
    snprintf(cmd, sizeof(cmd), 
        "$MyINFO $ALL %s Test Client$ $Cable$1$email@example.com$0|", 
        nick);
    send(sock, cmd, strlen(cmd), 0);
    
    // Send chat message
    snprintf(cmd, sizeof(cmd), "<%s> successfully connected|", nick);
    send(sock, cmd, strlen(cmd), 0);
    
    sleep(2);
    close(sock);
    free(lock);
    free(key);
    return 0;
}
```

## Common Hub Responses

| Command | Description |
|---------|-------------|
| `$Lock <string> Pk=<pk>\|` | Initial lock challenge |
| `$ValidateNick <nick>\|` | Nick needs validation |
| `$Hello <nick>\|` | Successfully logged in |
| `$GetPass\|` | Password required |
| `$BadPass\|` | Invalid password |
| `$LogedIn <nick>\|` | User logged in (operators) |
| `$NickList nick1$$nick2\|` | List of all users |
| `$MyINFO $ALL ...\|` | User info broadcast |
| `$Quit <nick>\|` | User disconnected |
| `$HubIsFull\|` | Hub at capacity |
| `$ValidateDenide <nick>\|` | Nick denied/taken |

## Implementation Tips

1. **Socket timeouts**: Set reasonable timeouts (3-5 seconds) for recv operations
2. **Buffer sizes**: Use 4096-byte buffers minimum for protocol messages
3. **Line parsing**: Split by `|` to handle multiple commands in one message
4. **Character encoding**: Use local charset (commonly Windows-1252/CP1252)
5. **Debug output**: Log all sent/received messages during development
6. **Blocking mode**: Use non-blocking or select() for reliable reads
7. **Connection keepalive**: Some hubs may disconnect idle clients

## Security Considerations

- No built-in encryption in base NMDC (use TLS extension for secure connections)
- Passwords sent in plain text after $GetPass
- Hub can redirect clients to arbitrary IPs (DDoS potential)
- Validate all user input to prevent injection attacks
