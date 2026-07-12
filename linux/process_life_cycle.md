## Process Life Cycle

This document explores how the Linux kernel manages a process from start to finish. We will follow an Nginx web server running on Ubuntu as our example throughout each stage of the journey.

### Setting Up the Environment

First, let us install Nginx and start it as a system service. For reference, here are the commands to install, enable, and launch Nginx:

```sh

$ sudo apt update

$ sudo apt install nginx -y

$ sudo nginx -version
nginx version: nginx/1.24.0 (Ubuntu)

$ sudo systemctl enable nginx
Synchronizing state of nginx.service with SysV service script with /usr/lib/systemd/systemd-sysv-install.
Executing: /usr/lib/systemd/systemd-sysv-install enable nginx

$ sudo systemctl start nginx

$ sudo systemctl status nginx
# Logs for reference
● nginx.service - A high performance web server and a reverse proxy server
     Loaded: loaded (/usr/lib/systemd/system/nginx.service; enabled; preset: enabled)
     Active: active (running) since Sun 2026-07-12 20:45:25 UTC; 2min 4s ago
       Docs: man:nginx(8)
   Main PID: 20667 (nginx)
      Tasks: 13 (limit: 26261)
     Memory: 9.1M (peak: 20.4M)
        CPU: 40ms
     CGroup: /system.slice/nginx.service
             ├─20667 "nginx: master process /usr/sbin/nginx -g daemon on; master_process on;"
             ├─20669 "nginx: worker process"
             ├─20670 "nginx: worker process"
             ├─20671 "nginx: worker process"
             ├─20672 "nginx: worker process"
```

### Check Process Details

Once Nginx is running, we can inspect its processes. For reference, here are the commands to look up process IDs and examine a process's kernel-level status:

```sh

$ pidof nginx
20680 20679 20678 20677 20676 20675 20674 20673 20672 20671 20670 20669 20667

$ cat /proc/20676/status
Name:	nginx
Umask:	0000
State:	S (sleeping)
Tgid:	20676
Ngid:	0
Pid:	20676
PPid:	20667

# Check nginx restart and trace fork events
$ sudo strace -f -e trace=fork -p 20667
strace: Process 20667 attached
--- SIGQUIT {si_signo=SIGQUIT, si_code=SI_USER, si_pid=82327, si_uid=0} ---
--- SIGCHLD {si_signo=SIGCHLD, si_code=CLD_EXITED, si_pid=20671, si_uid=33, si_status=0, si_utime=0, si_stime=0} ---
+++ exited with 0 +++

```

### Trace Traffic

With Nginx serving requests, we can watch network traffic arrive at the server. For reference, here is the command to capture HTTP packets on port 80 using `tcpdump`, along with sample output showing a three-way handshake and an incoming HTTP GET request:

```sh

$ sudo tcpdump -i ens18 tcp port 80

# Logs for reference
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on ens18, link-type EN10MB (Ethernet), snapshot length 262144 bytes
21:09:22.726155 IP 192.168.1.113.50469 > ub-k8s.http: Flags [SEW], seq 1852274421, win 65535, options [mss 1460,nop,wscale 6,nop,nop,TS val 3671615293 ecr 0,sackOK,eol], length 0
21:09:22.726214 IP ub-k8s.http > 192.168.1.113.50469: Flags [S.E], seq 3672414727, ack 1852274422, win 65160, options [mss 1460,sackOK,TS val 3097353500 ecr 3671615293,nop,wscale 7], length 0
21:09:22.730193 IP 192.168.1.113.50469 > ub-k8s.http: Flags [.], ack 1, win 2059, options [nop,nop,TS val 3671615297 ecr 3097353500], length 0
21:09:22.731487 IP 192.168.1.113.50469 > ub-k8s.http: Flags [P.], seq 1:435, ack 1, win 2059, options [nop,nop,TS val 3671615300 ecr 3097353500], length 434: HTTP: GET / HTTP/1.1
```

### Uncomplicated Firewall (UFW)

Before Nginx can accept connections, the firewall must allow traffic on port 80. For reference, here is the command to open port 80 using UFW:

```sh

$ sudo ufw allow 80/tcp
Rules updated
Rules updated (v6)

```

### References

- [Install Nginx](https://docs.vultr.com/how-to-install-nginx-web-server-on-ubuntu-24-04)
