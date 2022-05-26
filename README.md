# Partial Replication
This is Proof of Concept to demonstrating Partial Replication using a mix of PGLogical and Conjur Policy.

## Demo
To run the demo:

#### Start
```sh
bin/start
```

This will start a Conjur instance with two Postgres instances (one as leader, one as partially replicating follower).

The start script leaves you in a shell.

#### Setup Partial Replication (with data)

To configure partial replication:

```sh
rake partial_replication:demo
```

This will load data, the required policy, and configure Postgres to replicate

#### Verify

To verify partial replication worked as expected log onto each postgres container:

- Leader: `psql postgres://postgres:Password123@localhost:5432/postgres`
- Follower: `psql postgres://postgres:Password123@localhost:5433/postgres`

and view secrets:

```sql
select * from secrets;
```
The follower should only include variables from the following:

- `production/my-app-1`
- `production/my-app-2`
- `production/my-app-3`
