# dap-follower-syncer
This is Proof of Concept to demonstrate an API based mechanism for partial policy tree replication.

## Demo
To run the demo:

#### Start
```sh
bin/start
```

This will start two DAP 11.7.0 running masters (on localhost ports `443` and `444`). The start script leaves you in a shell.

#### Load Data

To load sample data into the DAP source (`443`), run:

```sh
rake syncer:load_data
```

This will load a number of applications and postgres database credentials into a `production` and `staging` policy spaces. 

[Log in](https://localhost) to view the data.

#### Migrate Data

To migrate the `production` data to the source (`444`):

```sh
rake syncer:replicate
```
[Log in](https://localhost:444) to view the data.
