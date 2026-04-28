use std::collections::HashSet;
use std::fs;
use std::process::Command;

use tracing::{info, warn};

pub fn add_iptables_accept(ip: &str, mac: Option<&str>) {
    let check_args = iptables_args("-C", ip, mac);
    let status = Command::new("iptables").args(&check_args).status();
    if let Ok(s) = status {
        if s.success() {
            info!("iptables rule already exists for {} {:?}", ip, mac);
            return;
        }
    }

    let add_args = iptables_args("-I", ip, mac);
    match Command::new("iptables").args(&add_args).status() {
        Ok(s) if s.success() => info!("Added iptables ACCEPT for {} {:?}", ip, mac),
        Ok(_) => warn!("Failed to add iptables rule for {} {:?}", ip, mac),
        Err(e) => warn!("iptables command failed for {} {:?}: {}", ip, mac, e),
    }
}

pub fn remove_iptables_accept(ip: &str, mac: Option<&str>) {
    let args = iptables_args("-D", ip, mac);
    match Command::new("iptables").args(&args).status() {
        Ok(s) if s.success() => info!("Removed iptables ACCEPT for {} {:?}", ip, mac),
        Ok(_) => remove_iptables_accept_by_number(ip, mac),
        Err(e) => warn!("iptables command failed for {} {:?}: {}", ip, mac, e),
    }
}

fn iptables_args(action: &str, ip: &str, mac: Option<&str>) -> Vec<String> {
    let mut args = vec![
        action.to_string(),
        "CAPTIVE_AUTH".to_string(),
        "-s".to_string(),
        ip.to_string(),
    ];

    if let Some(mac) = mac {
        args.extend([
            "-m".to_string(),
            "mac".to_string(),
            "--mac-source".to_string(),
            mac.to_string(),
        ]);
    }

    args.extend(["-j".to_string(), "ACCEPT".to_string()]);
    args
}

pub fn mac_for_ip(ip: &str) -> Option<String> {
    let arp = fs::read_to_string("/proc/net/arp").ok()?;

    for line in arp.lines().skip(1) {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() >= 4 && fields[0] == ip {
            return normalize_mac(fields[3]);
        }
    }

    None
}

pub fn associated_macs(interface: &str) -> Option<HashSet<String>> {
    let output = Command::new("iw")
        .args(["dev", interface, "station", "dump"])
        .output()
        .ok()?;

    if !output.status.success() {
        warn!("Failed to read associated stations from {}", interface);
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let macs = stdout
        .lines()
        .filter_map(|line| line.trim().strip_prefix("Station "))
        .filter_map(|rest| rest.split_whitespace().next())
        .filter_map(normalize_mac)
        .collect();

    Some(macs)
}

pub fn arp_macs_for_device(device: &str) -> HashSet<String> {
    let Ok(arp) = fs::read_to_string("/proc/net/arp") else {
        return HashSet::new();
    };

    arp.lines()
        .skip(1)
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let _ip = fields.next()?;
            let _hw_type = fields.next()?;
            let flags = fields.next()?;
            let mac = fields.next()?;
            let _mask = fields.next()?;
            let iface = fields.next()?;

            if flags == "0x2" && iface == device {
                normalize_mac(mac)
            } else {
                None
            }
        })
        .collect()
}

pub fn authenticated_clients() -> Vec<(String, Option<String>)> {
    let output = Command::new("iptables")
        .args(["-S", "CAPTIVE_AUTH"])
        .output();

    let Ok(output) = output else {
        return Vec::new();
    };

    if !output.status.success() {
        return Vec::new();
    }

    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(parse_auth_rule)
        .collect()
}

fn remove_iptables_accept_by_number(ip: &str, mac: Option<&str>) {
    let output = Command::new("iptables")
        .args(["-S", "CAPTIVE_AUTH"])
        .output();

    let Ok(output) = output else {
        warn!("Failed to list iptables rules for {} {:?}", ip, mac);
        return;
    };

    if !output.status.success() {
        warn!("Failed to list iptables rules for {} {:?}", ip, mac);
        return;
    }

    let wanted_mac = mac.and_then(normalize_mac);
    let mut rule_numbers = Vec::new();
    let mut rule_number = 0;

    for line in String::from_utf8_lossy(&output.stdout).lines() {
        if !line.starts_with("-A CAPTIVE_AUTH ") {
            continue;
        }

        rule_number += 1;

        let Some((rule_ip, rule_mac)) = parse_auth_rule(line) else {
            continue;
        };

        if rule_ip == ip && (wanted_mac.is_none() || rule_mac == wanted_mac) {
            rule_numbers.push(rule_number);
        }
    }

    if rule_numbers.is_empty() {
        warn!("Failed to find iptables rule for {} {:?}", ip, mac);
        return;
    }

    for rule_number in rule_numbers.into_iter().rev() {
        match Command::new("iptables")
            .args(["-D", "CAPTIVE_AUTH", &rule_number.to_string()])
            .status()
        {
            Ok(s) if s.success() => info!(
                "Removed iptables ACCEPT #{} for {} {:?}",
                rule_number, ip, mac
            ),
            Ok(_) => warn!(
                "Failed to remove iptables rule #{} for {} {:?}",
                rule_number, ip, mac
            ),
            Err(e) => warn!("iptables command failed for {} {:?}: {}", ip, mac, e),
        }
    }
}

fn parse_auth_rule(line: &str) -> Option<(String, Option<String>)> {
    if !line.starts_with("-A CAPTIVE_AUTH ") {
        return None;
    }

    let mut ip = None;
    let mut mac = None;
    let mut fields = line.split_whitespace();

    while let Some(field) = fields.next() {
        match field {
            "-s" => {
                ip = fields
                    .next()
                    .map(|value| value.strip_suffix("/32").unwrap_or(value).to_string());
            }
            "--mac-source" => {
                mac = fields.next().and_then(normalize_mac);
            }
            _ => {}
        }
    }

    ip.map(|ip| (ip, mac))
}

fn normalize_mac(mac: &str) -> Option<String> {
    let mac = mac.trim().to_ascii_lowercase();
    let valid = mac.len() == 17
        && mac.chars().enumerate().all(|(i, c)| {
            if i % 3 == 2 {
                c == ':'
            } else {
                c.is_ascii_hexdigit()
            }
        });

    valid.then_some(mac)
}
