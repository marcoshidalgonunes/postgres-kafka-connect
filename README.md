# postgres-kafka-connect

Demo of how to stream tables from Postgres to Kafka/KSQL back to Postgres with custom Kakfka Connector.

It is based in [Maria Patterson demo](https://github.com/mtpatter/postgres-kafka-demo/tree/master) of how to stream tables from Postgres to Kafka/KSQL back to Postgres, with some adjustments for PostgreSQL data persistence and connect to Kafka with external tools.

## Data

The data used here was originally taken from the
[Graduate Admissions](https://www.kaggle.com/mohansacharya/graduate-admissions)
open dataset available on Kaggle.
The admit csv files are records of students and test scores with their chances
of college admission.  The research csv files contain a flag per student
for whether or not they have research experience.

## Components

The following technologies are used through Docker containers:
* Kafka, the streaming platform
* Zookeeper, Kafka's best friend
* KSQL server, which we will use to create real-time updating tables
* Kafka's schema registry, needed to use the Avro data format
* Kafka Connect, pulled from [Debezium](https://debezium.io/), which will
source and sink data back and forth through Kafka
* Postgres, pulled from [Debezium](https://debezium.io/), tailored for use with Connect

The containers are pulled directly from official Docker Hub images.
The Debezium Connect image used here needs some additional packages, so it must be built from the 
included Dockerfile. The same applies for Debezium Postgres.

### Build the debezium images for Kafka Connect and Postgres

```
docker build -t debezium-connect -f debezium.Dockerfile .
```

### Create volume for PostgreSQL

```
docker volume create postgresdata
```

### Bring up the entire environment

```
docker-compose up -d
```

## Loading data into Postgres

We will bring up a container with a psql command line, mount our local data
files inside, create a database called `students`, and load the data on
students' chance of admission into the `admission` table.

> To load data is used the `copy` command. Replace the path of files to be loaded according to your filesystem (Linux or Windows).

```
docker run -it --rm --network=postgres-kafka-connect_default \
         -v postgresdata:/var/lib/postgresql/data \
         debezium-postgres psql -h postgres -U postgres
```

Password = postgres

At the command line:

```
CREATE DATABASE students;
\connect students;
```

Load our admission data table:

```
CREATE TABLE admission
(student_id INTEGER, gre INTEGER, toefl INTEGER, cpga DOUBLE PRECISION, admit_chance DOUBLE PRECISION,
CONSTRAINT student_id_pk PRIMARY KEY (student_id));

\copy admission FROM 'data/admit_1.csv' DELIMITER ',' CSV HEADER
```

Load the research data table with:

```
CREATE TABLE research
(student_id INTEGER, rating INTEGER, research INTEGER,
PRIMARY KEY (student_id));

\copy research FROM 'data/research_1.csv' DELIMITER ',' CSV HEADER
```

## Use Postgres database as a source to Kafka and prepaa data to sink.

The `postgres-source.json` file contains the configuration settings needed to
sink all of the students database to Kafka.

```
curl -X POST -H "Accept:application/json" -H "Content-Type: application/json" \
      --data @postgres-source.json http://localhost:8083/connectors
```

The connector `postgres-source` should show up when curling for the list
of existing connectors:

```
curl -H "Accept:application/json" localhost:8083/connectors/
```

The two tables in the `students` database will now show up as topics in Kafka.
You can check this by entering the Kafka container:

```
docker exec -it <kafka-container-id> /bin/bash
```

and listing the available topics:

```
/usr/bin/kafka-topics --list --zookeeper zookeeper:2181
```

### Create tables in KSQL

Bring up a KSQL server command line client as a container:

```
docker run --network postgres-kafka-connect_default \
           --interactive --tty --rm \
           confluentinc/cp-ksql-cli:latest \
           http://ksql-server:8088
```

To see your updates, a few settings need to be configured by first running:

```
set 'commit.interval.ms'='2000';
set 'cache.max.bytes.buffering'='10000000';
set 'auto.offset.reset'='earliest';
```

### Mirror Postgres tables

The Postgres table topics should be visible in KSQL:

```
SHOW TOPICS;

 Kafka Topic                | Partitions | Partition Replicas
--------------------------------------------------------------
 _schemas                   | 1          | 1
 connect-status             | 5          | 1
 dbserver1.public.admission | 1          | 1
 dbserver1.public.research  | 1          | 1
 my-connect-configs         | 1          | 1
 my-connect-offsets         | 25         | 1
--------------------------------------------------------------
```

We will create KSQL streams to auto update KSQL tables mirroring the Postgres tables:

```
CREATE STREAM admission_src (student_id INTEGER, gre INTEGER, toefl INTEGER, cpga DOUBLE, admit_chance DOUBLE)\
WITH (KAFKA_TOPIC='dbserver1.public.admission', VALUE_FORMAT='AVRO');

CREATE STREAM admission_src_rekey WITH (PARTITIONS=1) AS \
SELECT * FROM admission_src PARTITION BY student_id;

CREATE STREAM research_src (student_id INTEGER, rating INTEGER, research INTEGER)\
WITH (KAFKA_TOPIC='dbserver1.public.research', VALUE_FORMAT='AVRO');

CREATE STREAM research_src_rekey WITH (PARTITIONS=1) AS \
SELECT * FROM research_src PARTITION BY student_id;

SHOW STREAMS;

 Stream Name         | Kafka Topic                | Format
-----------------------------------------------------------
 ADMISSION_SRC       | dbserver1.public.admission | AVRO
 ADMISSION_SRC_REKEY | ADMISSION_SRC_REKEY        | AVRO
 RESEARCH_SRC        | dbserver1.public.research  | AVRO
 RESEARCH_SRC_REKEY  | RESEARCH_SRC_REKEY         | AVRO
-----------------------------------------------------------
```

Now we will create tables from Postgres topics. Currently KSQL uses uppercase casing convention 
for stream, table, and field names.


```
CREATE TABLE admission (student_id INTEGER, gre INTEGER, toefl INTEGER, cpga DOUBLE, admit_chance DOUBLE)\
WITH (KAFKA_TOPIC='ADMISSION_SRC_REKEY', VALUE_FORMAT='AVRO', KEY='student_id');

CREATE TABLE research (student_id INTEGER, rating INTEGER, research INTEGER)\
WITH (KAFKA_TOPIC='RESEARCH_SRC_REKEY', VALUE_FORMAT='AVRO', KEY='student_id');
```

### Create downstream tables

We will create a new KSQL streaming table to join students' chance of
admission with research experience.

```
CREATE TABLE research_boost AS \
  SELECT a.student_id as student_id, \
         a.admit_chance as admit_chance, \
         r.research as research \
  FROM admission a \
  LEFT JOIN research r on a.student_id = r.student_id;
```

and another table calculating the average chance of admission for
students with and without research experience:

```
CREATE TABLE research_ave_boost \
     WITH (KAFKA_TOPIC='research_ave_boost', VALUE_FORMAT='AVRO') \
     AS SELECT research, SUM(admit_chance)/COUNT(admit_chance) as ave_chance \
     FROM research_boost \
     GROUP BY research;
```

```
SHOW TABLES;

 Table Name         | Kafka Topic         | Format | Windowed
--------------------------------------------------------------
 ADMISSION          | ADMISSION_SRC_REKEY | AVRO   | false
 RESEARCH           | RESEARCH_SRC_REKEY  | AVRO   | false
 RESEARCH_AVE_BOOST | research_ave_boost  | AVRO   | false
 RESEARCH_BOOST     | RESEARCH_BOOST      | AVRO   | false
--------------------------------------------------------------
```

Now we can bring down the KSQL server command line client with the command `exit`.

## Add a connector to sink a KSQL table back to Postgres

The `postgres-sink.json` configuration file will create the `research_ave_boost`
table and send the data back to Postgres.

```
curl -X POST -H "Accept:application/json" -H "Content-Type: application/json" \
      --data @postgres-sink.json http://localhost:8083/connectors
```

Bring up once again the container with a psql command line:

```
docker run -it --rm --network=postgres-kafka-connect_default \
         -v postgresdata:/var/lib/postgresql/data \
         debezium-postgres psql -h postgres -U postgres
```

Password = postgres

At the command line:

```
SELECT ave_chance FROM research_ave_boost
  WHERE CAST(research as INT)=0;
```

With these data the average admission chance will be 65.19%.

The research field needs to be cast because it has been typed as text
instead of integer, which may be a bug in KSQL or Connect.

Add some new data to the admission and research tables in Postgres:

```
\copy admission FROM 'data/admit_2.csv' DELIMITER ',' CSV HEADER
\copy research FROM 'data/research_2.csv' DELIMITER ',' CSV HEADER
```

With the same query above on the RESEARCH_AVE_BOOST table, the
average chance of admission for students without research experience
has been updated to 63.49%.
