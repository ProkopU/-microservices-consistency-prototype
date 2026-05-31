workspace "Order System" "Demonstrační aplikace pro srovnání přístupů k datové konzistenci v mikroservisní architektuře." {

    model {

        # ── Aktéři ──────────────────────────────────────────────────────────
        customer = person "Zákazník" "Uživatel systému, který vytváří a sleduje objednávky."
        paymentGateway = softwareSystem "Platební brána" "Externí systém pro zpracování platebních transakcí (např. Stripe)." "External"

        # ── Systém ──────────────────────────────────────────────────────────
        orderSystem = softwareSystem "Order System" "Mikroservisní objednávkový systém demonstrující různé přístupy k datové konzistenci." {

            # API Gateway
            gateway = container "API Gateway" "Vstupní bod pro všechny klientské požadavky. Směruje požadavky na příslušné mikroservisy." "Spring Cloud Gateway" "Gateway"

            # Kafka
            kafka = container "Apache Kafka" "Message broker pro asynchronní komunikaci mezi mikroservisami." "Apache Kafka" "MessageBroker"

            # ── Order Service ────────────────────────────────────────────────
            orderService = container "Order Service" "Spravuje životní cyklus objednávek. Koordinuje proces vytvoření objednávky napříč ostatními službami." "Spring Boot" {
                orderController    = component "OrderController"    "REST API pro vytváření a správu objednávek."
                orderApplicationService = component "OrderApplicationService" "Orchestruje business procesy – synchronní i saga přístupy."
                sagaOrchestrator   = component "SagaOrchestrator"   "Centrální orchestrátor pro Saga orchestration pattern."
                orderDomainService = component "OrderDomainService" "Doménová logika, stavový automat objednávky."
                outboxPublisher    = component "OutboxPublisher"    "Čte zprávy z Outbox tabulky a publikuje je do Kafky."
                orderRepository    = component "OrderRepository"    "JPA přístup k databázi objednávek."
            }

            orderDb = container "Order DB" "PostgreSQL databáze objednávek. Obsahuje také Outbox tabulku." "PostgreSQL" "Database"

            # ── Payment Service ──────────────────────────────────────────────
            paymentService = container "Payment Service" "Zpracovává platební transakce. Komunikuje s externí platební bránou." "Spring Boot" {
                paymentController    = component "PaymentController"    "REST API pro správu plateb."
                paymentConsumer      = component "PaymentEventConsumer" "Konzument Kafka událostí z Order a Inventory Service."
                paymentDomainService = component "PaymentDomainService" "Doménová logika zpracování platby."
                acl                  = component "PaymentGatewayACL"    "Anti-Corruption Layer – překládá model platební brány do interní terminologie."
                paymentOutbox        = component "OutboxPublisher"      "Outbox publisher pro Payment Service."
                paymentRepository    = component "PaymentRepository"    "JPA přístup k databázi plateb."
            }

            paymentDb = container "Payment DB" "PostgreSQL databáze plateb. Obsahuje také Outbox tabulku." "PostgreSQL" "Database"

            # ── Inventory Service ────────────────────────────────────────────
            inventoryService = container "Inventory Service" "Spravuje stav skladu a rezervace zboží." "Spring Boot" {
                inventoryController    = component "InventoryController"    "REST API pro správu skladu."
                inventoryConsumer      = component "InventoryEventConsumer" "Konzument Kafka událostí z Order Service."
                inventoryDomainService = component "InventoryDomainService" "Doménová logika rezervací a skladových pohybů."
                inventoryOutbox        = component "OutboxPublisher"        "Outbox publisher pro Inventory Service."
                inventoryRepository    = component "InventoryRepository"    "JPA přístup k databázi skladu."
            }

            inventoryDb = container "Inventory DB" "PostgreSQL databáze skladu. Obsahuje také Outbox tabulku." "PostgreSQL" "Database"
        }

        # ── Vztahy – System Context ──────────────────────────────────────────
        customer       -> orderSystem    "Vytváří objednávky, sleduje jejich stav"
        orderSystem    -> paymentGateway "Zpracovává platby"

        # ── Vztahy – Container level ─────────────────────────────────────────
        customer       -> gateway         "HTTP/REST"
        gateway        -> orderService    "HTTP/REST"
        gateway        -> paymentService  "HTTP/REST"
        gateway        -> inventoryService "HTTP/REST"

        orderService   -> orderDb         "JDBC/JPA"
        paymentService -> paymentDb       "JDBC/JPA"
        inventoryService -> inventoryDb   "JDBC/JPA"

        orderService   -> kafka           "Publikuje: OrderCreated, OrderConfirmed, OrderCancelled, ReleaseStock"
        paymentService -> kafka           "Publikuje: PaymentCompleted, PaymentFailed"
        inventoryService -> kafka         "Publikuje: StockReserved, StockReservationFailed, StockReleased"

        kafka -> orderService    "Konzumuje: PaymentCompleted, PaymentFailed, StockReserved, StockReservationFailed"
        kafka -> paymentService  "Konzumuje: StockReserved"
        kafka -> inventoryService "Konzumuje: OrderCreated, ReleaseStock"

        paymentService -> paymentGateway "HTTPS – autorizace a capture platby"

        # ── Vztahy – Component level (Order Service) ─────────────────────────
        orderController         -> orderApplicationService  "volá"
        orderApplicationService -> sagaOrchestrator         "spouští orchestraci"
        orderApplicationService -> orderDomainService       "doménové operace"
        sagaOrchestrator        -> orderDomainService       "aktualizuje stav"
        orderDomainService      -> orderRepository          "persists"
        outboxPublisher         -> orderRepository          "čte Outbox záznamy"
        outboxPublisher         -> kafka                    "publikuje zprávy"
    }

    views {

        # System Context
        systemContext orderSystem "SystemContext" {
            include *
            autolayout lr
            title "System Context – Order System"
        }

        # Container view
        container orderSystem "Containers" {
            include *
            autolayout lr
            title "Container View – Order System"
        }

        # Component view – Order Service
        component orderService "OrderServiceComponents" {
            include *
            autolayout tb
            title "Component View – Order Service"
        }

        # Dynamický pohled – Saga choreografií
        dynamic orderSystem "SagaChoreography" "Saga choreografií – úspěšný scénář vytvoření objednávky" {
            customer      -> gateway          "POST /orders"
            gateway       -> orderService     "vytvoří objednávku (PENDING)"
            orderService  -> kafka            "OrderCreated"
            kafka         -> inventoryService "OrderCreated"
            inventoryService -> kafka         "StockReserved"
            kafka         -> paymentService   "StockReserved"
            paymentService -> kafka           "PaymentCompleted"
            kafka         -> orderService     "PaymentCompleted → CONFIRMED"
            autolayout lr
            title "Saga – choreografie (happy path)"
        }

        # Dynamický pohled – Saga orchestrací
        dynamic orderSystem "SagaOrchestration" "Saga orchestrací – úspěšný scénář vytvoření objednávky" {
            customer         -> gateway          "POST /orders"
            gateway          -> orderService     "spustí orchestrátor"
            orderService     -> kafka            "ReserveStock (příkaz)"
            kafka            -> inventoryService "ReserveStock"
            inventoryService -> kafka            "StockReserved (odpověď)"
            kafka            -> orderService     "StockReserved"
            orderService     -> kafka            "ProcessPayment (příkaz)"
            kafka            -> paymentService   "ProcessPayment"
            paymentService   -> kafka            "PaymentCompleted (odpověď)"
            kafka            -> orderService     "PaymentCompleted → CONFIRMED"
            autolayout lr
            title "Saga – orchestrace (happy path)"
        }

        styles {
            element "Person" {
                shape Person
                background #1F5C99
                color #ffffff
            }
            element "Software System" {
                background #2E75B6
                color #ffffff
            }
            element "External" {
                background #999999
                color #ffffff
            }
            element "Container" {
                background #4A90D9
                color #ffffff
            }
            element "Gateway" {
                background #2E75B6
                color #ffffff
                shape WebBrowser
            }
            element "MessageBroker" {
                background #E8A020
                color #ffffff
                shape Pipe
            }
            element "Database" {
                shape Cylinder
                background #336699
                color #ffffff
            }
            element "Component" {
                background #85B7EB
                color #000000
            }
        }
    }
}
