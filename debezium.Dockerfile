FROM quay.io/debezium/connect:3.0.0.Final

# https://github.com/debezium/debezium-examples/blob/master/unwrap-smt/debezium-jdbc-es/Dockerfile

ENV KAFKA_CONNECT_JDBC_DIR=$KAFKA_CONNECT_PLUGINS_DIR/kafka-connect-jdbc \
    KAFKA_CONNECT_ES_DIR=$KAFKA_CONNECT_PLUGINS_DIR/kafka-connect-elasticsearch

# Deploy PostgreSQL JDBC Driver
RUN cd /kafka/libs && curl -sO https://jdbc.postgresql.org/download/postgresql-42.7.4.jar

# Deploy Kafka Connect JDBC
RUN mkdir $KAFKA_CONNECT_JDBC_DIR && cd $KAFKA_CONNECT_JDBC_DIR &&\
	curl -sO http://packages.confluent.io/maven/io/confluent/kafka-connect-jdbc/5.1.2/kafka-connect-jdbc-10.8.0.jar

# Deploy Debezium and Confluent Avro Converter
COPY libs/*.jar /kafka/libs
