/****************************************************************
 * Copyright (C) 2017 Schneider Electric                        *
 *                                                              *
 * Derivative work: based on udhcpc_wrapper.c                   *
 ****************************************************************/

/**
 * @file dhclient_wrapper.c
 * @brief Wrapping calls to IDC's dhclient
 * @author Tomasz Kazimierz Motyl
 * @e-mail tomasz.motyl@schneider-electric.com
 * @version 0.1
 * @date 2017-10-17
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
//#define debug(args...)  fprintf(stderr, args...), fprintf(stderr, "\r\n")
//#define debugf(string) fprintf(stderr, format, ...), fprintf(stderr, "\r\n")
#else
#define debug(format, ...) 
#define debugf(string)
#endif


#define DHCLIENT_PATH        "/sbin/dhclient"
#define DHCLIENT_SCRIPT_PATH "/sbin/dhclient-script"

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

static char *get_ip6_addr(char * restrict dest, char * restrict ip6_prefix, char * restrict ip6_address, char * restrict ip6_prefixlen)
{
    if (ip6_prefix != NULL) {
      strncpy(dest, ip6_prefix, INET6_ADDRSTRLEN);
    } else if((ip6_address != NULL) && (ip6_prefixlen != NULL)) {
        snprintf(dest, INET6_ADDRSTRLEN, "%s/%s", ip6_address, ip6_prefixlen);
    }

    return dest; /* in DA60 format */
}

/* The Dhclient's environment variables input to the script:
 * reason
 * interface
 * new_ip6_address, ip6_prefixlen - if no new_ip6_prefix avaial
 * new_ip6_prefix
 * new_dhcp6_domain_search
 * new_dhcp6_name_servers
 * old_ip6_address - for release,expire and stop
 */
static void process_dhclient_script_callback(const int argc, char *argv[])
{
    char new_ip6_addr[INET6_ADDRSTRLEN] = {'\0', };
    char old_ip6_addr[INET6_ADDRSTRLEN] = {'\0', };

    char * new_ip6_prefix    = getenv("new_ip6_prefix"); /* IP address in Address/Prefix DA60 format */
    char * new_ip6_address   = getenv("new_ip6_address");
    char * new_ip6_prefixlen = getenv("new_ip6_prefixlen");

    char * old_ip6_prefix    = getenv("old_ip6_prefix"); /* IP address in Address/Prefix DA60 format */
    char * old_ip6_address   = getenv("old_ip6_address");
    char * old_ip6_prefixlen = getenv("old_ip6_prefixlen");

    (void) argc; // Guaranteed to be >=2
    (void) argv;

    /* If the user tells dhclient to call this program as the script
       (-isf script option), format and print the dhclient result nicely. */

    printf("%s,%s,%s,%s,%s,%s,%s\n",
           argv[0],
            getenv_nonull("reason"),
            getenv_nonull("interface"),
            get_ip6_addr(&new_ip6_addr[0], new_ip6_prefix, new_ip6_address, new_ip6_prefixlen),
            getenv_nonull("new_dhcp6_domain_search"),
            getenv_nonull("new_dhcp6_name_servers"),
            get_ip6_addr(&old_ip6_addr[0], old_ip6_prefix, old_ip6_address, old_ip6_prefixlen)
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
