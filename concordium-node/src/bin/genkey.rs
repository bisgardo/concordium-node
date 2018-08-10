#[macro_use]
extern crate structopt;
extern crate p2p_client;

use p2p_client::utils::{generate_ed25519_key, to_hex_string};
use std::fs::OpenOptions;
use std::io::Write;
use std::process::exit;
use structopt::StructOpt;

#[derive(StructOpt, Debug)]
#[structopt(name = "DNS Key Generator")]
struct ConfigCli {
    #[structopt(long = "keyfile", help = "Output key to file in binary")]
    keyfile: String,
    #[structopt(long = "print-key",
                short = "p",
                help = "Print key as HEX when done")]
    print_key: bool,
}

pub fn main() {
    let conf = ConfigCli::from_args();
    match OpenOptions::new().read(true)
                            .write(true)
                            .create(true)
                            .open(&conf.keyfile)
    {
        Ok(mut file) => {
            let key: [u8; 32] = generate_ed25519_key();
            match file.write_all(&key) {
                Ok(_) => {
                    println!("Key written to {}", &conf.keyfile);
                    if conf.print_key {
                        println!("Key written to file is {}", to_hex_string(&key));
                    }
                }
                Err(e) => {
                    println!("Couldn't write file {}", e);
                    exit(1);
                }
            }
        }
        Err(e) => {
            println!("Can't open file {}", e);
            exit(1);
        }
    }
    exit(0);
}
