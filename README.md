# Order System – Prototype

A demonstration application for comparing approaches to data consistency in a microservice architecture.

## Project Structure

```
prototype/
  model/
    workspace.dsl             ← Structurizr DSL – architectural view (C4 model)
    order-system.cml          ← Context Mapper CML – domain model (DDD)
    order-system.jdl          ← JHipster JDL – complete model (reference file)
    apps/
      gateway.jdl             ← JDL for API Gateway
      order-service.jdl       ← JDL for Order Service
      payment-service.jdl     ← JDL for Payment Service
      inventory-service.jdl   ← JDL for Inventory Service
  gateway/                    ← generated application (after running JHipster)
  order-service/              ← generated application (after running JHipster)
  payment-service/            ← generated application (after running JHipster)
  inventory-service/          ← generated application (after running JHipster)
  docker-compose/             ← docker-compose for the entire system (after running jhipster docker-compose)
```

## Services

| Service           | Port | Database   | Responsibility                      |
|-------------------|------|------------|-------------------------------------|
| gateway           | 8080 | –          | API Gateway, routing                |
| order-service     | 8081 | PostgreSQL | Orders, saga coordination           |
| payment-service   | 8082 | PostgreSQL | Payments, payment gateway           |
| inventory-service | 8083 | PostgreSQL | Stock management, reservations      |

## Kafka Topics

| Topic                    | Producer          | Consumer(s)                      |
|--------------------------|-------------------|----------------------------------|
| order.created            | order-service     | inventory-service                |
| order.confirmed          | order-service     | –                                |
| order.cancelled          | order-service     | –                                |
| stock.reserved           | inventory-service | payment-service                  |
| stock.reservation.failed | inventory-service | order-service                    |
| stock.released           | inventory-service | order-service                    |
| payment.completed        | payment-service   | order-service                    |
| payment.failed           | payment-service   | order-service, inventory-service |

## Prerequisites

- **Java 21+** (JHipster 9 does not support older versions)
- Node.js 18+
- JHipster: `npm install -g generator-jhipster`
- Docker Desktop

Verify the active Java version before proceeding:

```bash
java -version  # must show openjdk version "21" or higher
```

## Generating the Application Skeleton

### Step 1 – Generate individual microservices

Each microservice is generated separately into its own directory:

```bash
# From the project root (prototype/)

mkdir gateway order-service payment-service inventory-service

cd gateway
jhipster jdl ../model/apps/gateway.jdl
cd ..

cd order-service
jhipster jdl ../model/apps/order-service.jdl
cd ..

cd payment-service
jhipster jdl ../model/apps/payment-service.jdl
cd ..

cd inventory-service
jhipster jdl ../model/apps/inventory-service.jdl
cd ..
```

### Step 2 – Generate Docker Compose for the entire system

After generating all four applications, generate a shared Docker Compose configuration:

```bash
mkdir docker-compose
cd docker-compose
jhipster docker-compose
```

When prompted, select all four applications and set the root directory to `../`.

### Step 3 – Build Docker images

Each application must be built as a Docker image before it can be started.
Run the following from the project root:

```bash
cd order-service
./mvnw -ntp verify -DskipTests jib:dockerBuild
cd ..

cd payment-service
./mvnw -ntp verify -DskipTests jib:dockerBuild
cd ..

cd inventory-service
./mvnw -ntp verify -DskipTests jib:dockerBuild
cd ..

cd gateway
./mvnw -ntp verify -DskipTests jib:dockerBuild
cd ..
```

Building each service may take several minutes as Maven downloads dependencies and compiles the code.

### Step 4 – Start the entire system

```bash
cd docker-compose
docker-compose up -d
```

This starts all four applications along with three PostgreSQL databases, Kafka, Zookeeper and Consul.

Verify that all services are running:

```bash
docker-compose ps
```

## Viewing the Structurizr Model

The `workspace.dsl` file can be viewed:

- **Online:** https://structurizr.com/dsl – paste the file contents into the editor
- **Locally:** `docker run -it --rm -p 8080:8080 -v ./model:/usr/local/structurizr structurizr/lite`

Available views:
- `SystemContext` – high-level system overview
- `Containers` – microservices, Kafka, databases
- `OrderServiceComponents` – internal structure of Order Service
- `SagaChoreography` – choreography-based saga flow
- `SagaOrchestration` – orchestration-based saga flow

## Viewing Context Mapper Diagrams

Open `order-system.cml` in VS Code with the Context Mapper extension installed.
Generate diagrams via the Command Palette (Cmd+Shift+P / Ctrl+Shift+P):
- `Context Mapper: Generate PlantUML Diagrams`
- `Context Mapper: Generate Context Map Graphic`

Generated `.puml` files can be viewed using the PlantUML extension (Alt+D) or at plantuml.com.

## Implemented Consistency Approaches

After generating the skeleton, business logic is added manually to each microservice:

1. **Synchronous baseline** (`@Transactional`) – intentionally demonstrates the limitations of classical transactions in a distributed environment
2. **Saga choreography** – asynchronous communication via Kafka, each service reacts to events independently
3. **Saga orchestration** – a central orchestrator in Order Service coordinates the entire process
4. **Outbox pattern** – reliable message delivery, implemented in all three services
5. **Event sourcing** – basic demonstration in Order Service
