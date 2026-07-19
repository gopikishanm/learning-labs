## eBPF

In the past, adding advanced networking features meant routing every packet through a user-space agent or writing custom kernel modules. Both approaches came with serious trade-offs.

Traditional networking suffers from several problems:

- **High Latency and Overhead:** Classic tools like iptables evaluate rules one after another in a long, linear chain. Checking every packet against this entire sequence creates significant delays.
- **Context Switches:** Inspecting and routing packets often requires copying data between kernel space and user space. Every switch between these two layers eats up CPU cycles and slows things down.
- **Lack of Flexibility:** iptables and the traditional routing stack were built long before containers, microservices, and dynamic cloud-native environments became the norm. They simply weren't designed for today's infrastructure.

eBPF (Extended Berkeley Packet Filter) changes the game. It lets developers run sandboxed programs directly inside the Linux kernel, without modifying kernel source code or loading risky modules.

Here is how eBPF solves the problems above:

- **Constant Time Lookups:** Instead of walking through a chain of rules, eBPF uses hash tables (called maps) to look up policies and routing paths in a single, predictable step.
- **XDP (eXpress Data Path):** With XDP, eBPF programs can process packets the moment they arrive at the network interface card — before the kernel's main network stack even touches them. This delivers maximum throughput.
- **Reduced Context Switches:** eBPF filters, routes, and collects metrics right where the packet lands. There is no need to copy raw data up to user space, which cuts down on overhead dramatically.
- **Built-in Safety (The Verifier):** Before any eBPF program runs, the kernel puts it through a strict validator. This verifier checks for infinite loops, unauthorized memory access, and other dangerous behavior. If the program doesn't pass, it never executes.

For reference, here is a diagram that compares traditional Linux networking side-by-side with eBPF-accelerated networking:

```mermaid

graph TD
    %% Subgraph definitions for layout
    subgraph Traditional_Stack [Traditional Linux Networking]
        direction TB
        NIC1[1. Network Interface Card] -->|Driver / Ring Buffer| RX1[2. RX Queue & SoftIRQ]
        RX1 -->|SKB Allocation| NetStack[3. Linux Network Stack <br> i.e., IP/TCP Processing]
        NetStack -->|Sequential Rule Evaluation| IPTables{4. iptables / Netfilter}
        IPTables -->|Match / Drop / Route| Socket1[5. Socket Buffer]
        Socket1 -->|Context Switch & Copy| UserSpace1([6. User Space Application])
    end

    subgraph eBPF_Stack [eBPF Accelerated Networking]
        direction TB
        NIC2[1. Network Interface Card] -->|Driver Level Initialization| XDP[2. XDP / eBPF Program]
        
        XDP -->|Pass / Forward| CustomMap[(eBPF Maps)]
        XDP -->|Fast Drop / BPF_DROP| Drop([Drop Packet Early])
        XDP -->|Fast Redirect / BPF_REDIRECT| NIC_Out([Direct to Another NIC])
        
        XDP -->|Pass Remaining / BPF_PASS| TC[3. Traffic Control eBPF]
        TC -->|Bypass Socket Layer / BPF_SOCKMAP| UserSpace2([4. User Space Application])
    end

    %% Styling
    style Traditional_Stack fill:#f9f9f9,stroke:#333,stroke-width:2px;
    style eBPF_Stack fill:#f0f7ff,stroke:#0066cc,stroke-width:2px;
    style XDP fill:#ff9900,stroke:#333,stroke-width:2px;
    style Drop fill:#ffcccc,stroke:#cc0000;
    style IPTables fill:#ffffcc,stroke:#333;

```

### Core XDP Verdict Actions

XDP (eXpress Data Path) programs must return one of five verdict actions that tell the kernel what to do with a packet. The following diagram shows each possible verdict and its effect:

```mermaid

graph TD
    Packet([Incoming Packet]) --> XDP{eBPF XDP Program}
    XDP -->|XDP_DROP| Drop[Drop Packet Immediately]
    XDP -->|XDP_TX| TX[Bounce Back Out Same NIC]
    XDP -->|XDP_REDIRECT| Redirect[Forward to Another NIC/CPU]
    XDP -->|XDP_PASS| Pass[Send up to Linux Network Stack]
    XDP -->|XDP_ABORTED| Aborted[Program Error / Drop]

    style Drop fill:#ffcccc,stroke:#cc0000;
    style TX fill:#ffe6cc,stroke:#ff9900;
    style Redirect fill:#e1f5fe,stroke:#0288d1;
    style Pass fill:#e8f5e9,stroke:#388e3c;
    style Aborted fill:#f5f5f5,stroke:#616161;

```

### References

- [eBPF](https://www.linuxfoundation.org/hubfs/eBPF/The_State_of_eBPF25_111925.pdf)
- [Netkit](https://isovalent.com/blog/post/cilium-netkit-a-new-container-networking-paradigm-for-the-ai-era/)
- [Cloudfare Ddos](https://blog.cloudflare.com/defending-the-internet-how-cloudflare-blocked-a-monumental-7-3-tbps-ddos/)
- [eBPF Applications](https://ebpf.io/applications/)