use std::env;
use std::net::{IpAddr, SocketAddr};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpSocket;

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 5 {
        eprintln!("usage: http-bind-get <source-ip> <dest-ip> <dest-port> <path>");
        std::process::exit(2);
    }

    let source_ip: IpAddr = args[1].parse().expect("invalid source IP");
    let dest_ip: IpAddr = args[2].parse().expect("invalid destination IP");
    let dest_port: u16 = args[3].parse().expect("invalid destination port");
    let path = &args[4];

    let socket = match source_ip {
        IpAddr::V4(_) => TcpSocket::new_v4().expect("failed to create IPv4 socket"),
        IpAddr::V6(_) => TcpSocket::new_v6().expect("failed to create IPv6 socket"),
    };
    socket
        .bind(SocketAddr::new(source_ip, 0))
        .expect("failed to bind source address");

    let mut stream = socket
        .connect(SocketAddr::new(dest_ip, dest_port))
        .await
        .expect("failed to connect");
    eprintln!(
        "connected local={} peer={}",
        stream.local_addr().expect("missing local address"),
        stream.peer_addr().expect("missing peer address")
    );
    let request = format!(
        "GET {} HTTP/1.0\r\nHost: {}:{}\r\nConnection: close\r\n\r\n",
        path, dest_ip, dest_port
    );
    stream
        .write_all(request.as_bytes())
        .await
        .expect("failed to write request");

    let mut response = Vec::new();
    stream
        .read_to_end(&mut response)
        .await
        .expect("failed to read response");
    print!("{}", String::from_utf8_lossy(&response));
}
