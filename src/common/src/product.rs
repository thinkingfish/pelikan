/// Expands to the standard product `main()`: panic hook, CLI parsing,
/// `--stats` metric listing, config load, optional `--config` printing,
/// then launch.
///
/// A macro rather than a generic fn so every binary stays monomorphic and
/// the expanded tokens resolve against the product's own dependency set;
/// `common` itself needs no clap/metriken/logger edges. Callers must have
/// `#[macro_use] extern crate logger` in scope for the `debug!` line.
///
/// `print_config: true` requires the config type to implement `print()`;
/// omit the field for configs that cannot print themselves.
#[macro_export]
macro_rules! pelikan_main {
    (
        about: $about:expr,
        config: $config:ty,
        percentiles: $percentiles:expr,
        $(print_config: $print_config:literal,)?
        launch: $launch:expr $(,)?
    ) => {
        fn main() {
            // custom panic hook to terminate whole process after unwinding
            ::std::panic::set_hook(::std::boxed::Box::new(|s| {
                eprintln!("{s}");
                eprintln!("{:?}", ::backtrace::Backtrace::new());
                ::std::process::exit(101);
            }));

            // parse command line options
            let mut command = ::clap::Command::new(env!("CARGO_BIN_NAME"))
                .version(env!("CARGO_PKG_VERSION"))
                .long_about($about)
                .arg(
                    ::clap::Arg::new("stats")
                        .short('s')
                        .long("stats")
                        .help("List all metrics in stats")
                        .action(::clap::ArgAction::SetTrue),
                )
                .arg(
                    ::clap::Arg::new("CONFIG")
                        .help("Server configuration file")
                        .action(::clap::ArgAction::Set)
                        .index(1),
                );
            $(
                let _: bool = $print_config;
                command = command.arg(
                    ::clap::Arg::new("print-config")
                        .short('c')
                        .long("config")
                        .help("List all options in config")
                        .action(::clap::ArgAction::SetTrue),
                );
            )?
            let matches = command.get_matches();

            // output stats descriptions and exit if the `stats` option was provided
            if matches.get_flag("stats") {
                println!("{:<31} {:<15} DESCRIPTION", "NAME", "TYPE");

                let mut metrics = ::std::vec::Vec::new();

                for metric in &::metriken::metrics() {
                    let any = match metric.as_any() {
                        Some(any) => any,
                        None => {
                            continue;
                        }
                    };

                    if any.downcast_ref::<::metriken::Counter>().is_some() {
                        metrics.push(format!("{:<31} counter", metric.name()));
                    } else if any.downcast_ref::<::metriken::Gauge>().is_some() {
                        metrics.push(format!("{:<31} gauge", metric.name()));
                    } else if any.downcast_ref::<::metriken::AtomicHistogram>().is_some()
                        || any.downcast_ref::<::metriken::RwLockHistogram>().is_some()
                    {
                        for (label, _) in $percentiles {
                            let name = format!("{}_{}", metric.name(), label);
                            metrics.push(format!("{name:<31} percentile"));
                        }
                    } else {
                        continue;
                    }
                }

                metrics.sort();
                for metric in metrics {
                    println!("{metric}");
                }
                ::std::process::exit(0);
            }

            // load config from file
            let config: $config = if let Some(file) = matches.get_one::<String>("CONFIG") {
                debug!("loading config: {file}");
                match <$config>::load(file) {
                    Ok(c) => c,
                    Err(error) => {
                        eprintln!("error loading config file: {file}\n{error}");
                        ::std::process::exit(1);
                    }
                }
            } else {
                Default::default()
            };

            $(
                let _: bool = $print_config;
                if matches.get_flag("print-config") {
                    config.print();
                    ::std::process::exit(0);
                }
            )?

            ($launch)(config)
        }
    };
}
