/****************************************************************
 * Copyright (C) 2017 Schneider Electric                        *
 *                                                              *
 * Derivative work: based on udhcpc_wrapper.c                   *
 ****************************************************************/

/**
 * @file dhclientv4_wrapper.c
 * @brief Wrapping calls to IDC's dhclient
 * @author Alan Jackson
 * @e-mail tomasz.motyl@schneider-electric.com
 * @version 0.1
 * @date 2018-06-23
 */

#define _GNU_SOURCE

#include <errno.h>
#include <err.h>
#include <poll.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <signal.h>
#include <string.h>
#include <stdio.h>

#include <arpa/inet.h>

#define DEBUG
#ifdef DEBUG
#define debug(args...)  fprintf(stderr, args...), fprintf(stderr, "\r\n")
#define debugf(string) fprintf(stderr, format, ...), fprintf(stderr, "\r\n")
#else
#define debug(format, ...)
#define debugf(string)
#endif


#define DHCLIENT_PATH        "/sbin/dhclient"
// #define DHCLIENT_SCRIPT_PATH "/sbin/dhclient-script" 

static pid_t child_pid;
static int   exit_pipe_fd[2];


/**
 * @brief Dhclient needs to run with a real identify (ruid) of root.
 * Marking the dhclient_wrapper binary as setuid root isn't nsufficient because that only updates the effective and saved uids.
 */
static void force_identity(void) {
    uid_t ruid = 0;
    uid_t euid = 0;
    uid_t suid = 0 ;

    if(getresuid(&ruid, &euid, &suid) != 0) {
        errx(EXIT_FAILURE, "Can't get real, effectiv and/or saved UID! errno = %d; err = '%s'", errno, strerror(errno));
    }

    if (ruid != 0) {
        if (setresuid(euid, euid, euid) < 0) {
            errx(EXIT_FAILURE, "Can't elevate to root permissions required by dhclient! errno = %d; err = '%s'", errno, strerror(errno));
        }
    }
}

static void signal_handler(int sig)
{
    if (sig == SIGCHLD) {
        /* On SIGCHLD, write a byte to the pipe to wake up poll */
        char buffer = 0;

        if (write(exit_pipe_fd[1], &buffer, 1) < 0) {
            err(EXIT_FAILURE, "Unable to write to the inter-process pipe; errno = %d; err = '%s'", errno, strerror(errno));
        }
    } else {
        /* Pass the signal onto the child */
        kill(child_pid, sig);
    }
}

static void child(int argc, char *argv[])
{
    /* Launch the child with arguments */
    char *child_argv[argc + 1];
    child_argv[0] = strdup(DHCLIENT_PATH);

    memcpy(&child_argv[1], &argv[1], (argc - 1) * sizeof(char *));
    child_argv[argc] = NULL;

    execv(child_argv[0], child_argv);
    err(EXIT_FAILURE, "execv; errno = %d; err = '%s'", errno, strerror(errno));
}

typedef enum {
    RENEW   = 1,
    RELEASE = 2,
    EXIT    = 3,
} erlang_client_command;


static void process_erlang_request(void)
{
    char buffer[128] = {'\0', };
    ssize_t amount = read(STDIN_FILENO, buffer, sizeof(buffer));
    ssize_t i;


    if (amount <= 0) {
        /* Error or Erlang closed the port -> we're done. */
        kill(child_pid, SIGKILL);
        fprintf(stderr, "[%s %d]: Exitting...\r\n", __FILE__, __LINE__);
        exit(EXIT_SUCCESS);
    }

    for (i = 0; i < amount; i++) {
        /* Each command is a byte. */
        switch ((erlang_client_command) buffer[i]) {
            case RENEW:
                fprintf(stderr, "[%s %d]: Erlang RENEW request\r\n", __FILE__, __LINE__);
                kill(child_pid, SIGUSR1);
                break;
            case RELEASE: // release
                fprintf(stderr, "[%s %d]: Erlang RELEASE request\r\n", __FILE__, __LINE__);
                kill(child_pid, SIGUSR2);
                break;
            case EXIT:
                fprintf(stderr, "[%s %d]: Erlang EXIT request\r\n", __FILE__, __LINE__);
                kill(child_pid, SIGKILL);
                exit(EXIT_SUCCESS);
                break;
            default:
                fprintf(stderr, "[%s %d]: Erlang UNKNOWN request\r\n", __FILE__, __LINE__);
                kill(child_pid, SIGKILL);
                errx(EXIT_FAILURE, "unexpected command: %d", (int) buffer[i]);
        }
    }
}

static void parent()
{
    for (;;) {
        struct pollfd fdset[2] = {
            {.fd = STDIN_FILENO,    .events = POLLIN, .revents = 0, },
            {.fd = exit_pipe_fd[0], .events = POLLIN, .revents = 0, },
        };

        int rc = poll(fdset, 2, -1);

        fprintf(stderr, "[%s %d]: %s rc = %d\r\n", __FILE__, __LINE__, __FUNCTION__, rc);

        if (rc < 0) {
            /* Ignore EINTR */
            if (errno == EINTR)
                continue;

            kill(child_pid, SIGKILL);
            err(EXIT_FAILURE, "poll failed; errno = %d; err = '%s'", errno, strerror(errno));
        }

        if (fdset[0].revents & (POLLIN | POLLHUP))
            process_erlang_request();

        if (fdset[1].revents & (POLLIN | POLLHUP)) {
            /* When the child exits, we exit. */
            fprintf(stderr, "[%s %d]: %s Child exitted, so are we...\r\n", __FILE__, __LINE__, __FUNCTION__);
            return;
        }
    }
}

static void run_dhclient(const int argc, char *argv[])
{
    struct sigaction sigact = {
        .sa_handler = signal_handler,
        .sa_flags   = 0,
    };

    /* Make sure the udhcpc has ian effective root permission to run before going farther */
    force_identity();

    /* Set up a pipe for notifying the parent's polling loop of a SIGCHLD. */
    if (pipe(exit_pipe_fd) < 0) {
        err(EXIT_FAILURE, "Unable to set-up the inter-process pipe!");
    }

    /* Capture SIGCHLD and other relevant signals */
    if(sigemptyset(&sigact.sa_mask) != 0) {
        err(EXIT_FAILURE, "Unable to set the signal mask! errno = %d; err = '%s'!", errno, strerror(errno));
    }

    if(sigaction(SIGCHLD, &sigact, NULL) != 0) {
        err(EXIT_FAILURE, "Unable to set-up handler for a SIGCHLD signal: errno = %d; err = '%s'!", errno, strerror(errno));
    }

    if(sigaction(SIGINT,  &sigact, NULL) != 0) {
        err(EXIT_FAILURE, "Unable to set-up handler for a SIGCINT signal: errno = %d; err = '%s'!", errno, strerror(errno));
    }

    /* Fork */
    child_pid = fork(); /* TODO: consider using vfork so we would not have to close various file descriptors but we would have to call execve instead of execv */

    if (child_pid < 0)
        err(EXIT_FAILURE, "fork");

    if (child_pid == 0) {
        child(argc, argv);
    } else {
        parent();
    }

}

static const char * getenv_nonull(const char * restrict key)
{
    const char * restrict result = getenv(key);
    return result != NULL ? result : "";
}

static char *get_ip_addr(char * restrict dest, char * restrict ip_netmask, char * restrict ip_address, char * restrict ip_netmasklen)
{
    if (ip_netmask != NULL) {
      strncpy(dest, ip_netmask, INET_ADDRSTRLEN);
    } else if((ip_address != NULL) && (ip_netmasklen != NULL)) {
        snprintf(dest, INET_ADDRSTRLEN, "%s/%s", ip_address, ip_netmasklen);
    }
    
    return dest; /* in DA60 format */
}

/* The Dhclient's environment variables input to the script:
 * reason
 * interface
 * new_ip_address, ip_prefixlen - if no new_prefix avaial
 * new_prefix
 * new_domain_search
 * new_domain_name_servers
 * old_ip_address - for release,expire and stop
 * 
 * From reading /sbin/dhclient-script on NMC3 Filesystem, the following options
 * for 'reason' are outlined below:
 *
    +----------+--------------------------------------------------+
    |  Reason  |                      Action                      |
    +----------+--------------------------------------------------+
    | MEDIUM   | No Action                                        |
    | PREINIT  | ifup                                             |
    | ARPCHECK | No Action                                        |
    | ARPSEND  | No Action                                        |
    | BOUND    | Update ifconfig with new configuration           |
    | RENEW    | Update ifconfig with new configuration           |
    | REBIND   | Update ifconfig with new configuration           |
    | REBOOT   | Update ifconfig with new configuration           |
    | EXPIRE   | ifdown                                           |
    | FAIL     | ifdown                                           |
    | RELEASE  | ifdown                                           |
    | STOP     | ifdown                                           |
    | TIMEOUT  | No Action -> was never tested in dhclient-script |
    +----------+--------------------------------------------------+
 */
static void process_dhclient_script_callback(const int argc, char *argv[])
{
        /* If the user tells dhclient to call this program as the script
       (-isf script option), format and print the dhclient result nicely. */

    fprintf(stderr, "%s,%s,%s,%s,%s,%s,%s,%s\n",
            getenv_nonull("reason"),
            getenv_nonull("interface"),
            getenv_nonull("new_ip_address"),
            getenv_nonull("new_broadcast_address"),
            getenv_nonull("new_subnet_mask"),
            getenv_nonull("new_routers"),
            getenv_nonull("new_domain_name"),
            getenv_nonull("new_domain_name_servers")
    );
}

int main(int argc, char *argv[])
{
    if ((argc >= 2) && (strncmp(argv[1], "dhclient", strlen("dhclient")) == 0)) {
        run_dhclient(argc - 1, &argv[1]);
    } else {
        process_dhclient_script_callback(argc, argv);
    }

    exit(EXIT_SUCCESS);
}
