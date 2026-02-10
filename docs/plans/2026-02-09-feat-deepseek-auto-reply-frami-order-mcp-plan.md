---
title: "feat: Automatyczne odpowiedzi AI (DeepSeek V3.2) z integracją systemu zamówień Frami przez MCP"
type: feat
date: 2026-02-09
---

# Automatyczne odpowiedzi AI (DeepSeek V3.2) z integracją systemu zamówień Frami przez MCP

## Kontekst

Zero Email posiada rozbudowany system agentów AI (ZeroAgent + ZeroMCP) działający na Cloudflare Workers/Durable Objects z Vercel AI SDK. Rozszerzamy go o:

1. **DeepSeek V3.2** jako LLM (zamiast Claude) - przez provider `@ai-sdk/deepseek` dla Vercel AI SDK
2. **Frami Order System MCP** - łączy się z prawdziwym Django REST API (`~/Development/framky/frami-composer`)
3. **Automatyczna analiza maili** - przy synchronizacji DeepSeek analizuje nowe maile, tworzy drafty lub pyta o wskazówki
4. **Routing oparty na pewności** - wysoka pewność → auto-draft, niska → pytanie do użytkownika
5. **Gromadzenie wiedzy** - uczy się ze wskazówek użytkownika na przyszłość
6. **Dostęp do historii nadawcy** - pobiera inne maile od tego samego nadawcy jako kontekst

---

## Architektura

```
Nowy mail przychodzi (przez SyncThreadsWorkflow)
        |
        v
AutoReplyAnalyzer (nowy serwis)
        |
        v
DeepSeek V3.2 (przez @ai-sdk/deepseek) + Narzędzia:
  - FramiOrderMCP (nowy) → dane zamówień/przesyłek z Django API frami-composer
  - ZeroMCP (istniejący) → narzędzia mailowe (getThread, listThreads, searchByEmail)
  - Baza wiedzy → scenariusze w PostgreSQL + embeddingi w Vectorize
        |
        +--[Wysoka pewność]----→ Twórz Draft → Użytkownik sprawdza
        |
        +--[Niska pewność]-----→ Zapisz pytania → Pokaż w UI gdy użytkownik otworzy maila
        |
        +--[Średnia pewność]---→ Twórz Draft + Oznacz do przeglądu
```

---

## Faza 1: Integracja DeepSeek V3.2

### 1.1 Instalacja providera

```bash
pnpm add @ai-sdk/deepseek --filter=@zero/server
```

### 1.2 Konfiguracja środowiska

**Plik:** `apps/server/src/env.ts` - dodać do `ZeroEnv`:
```typescript
DEEPSEEK_API_KEY: string;
DEEPSEEK_MODEL: string;          // domyślnie: 'deepseek-chat'
FRAMI_API_URL: string;           // np. 'http://localhost:8000' lub URL produkcyjny
FRAMI_API_TOKEN: string;         // token Django Token auth
```

**Plik:** `apps/server/wrangler.jsonc` - dodać zmienne środowiskowe do `[vars]`

**Plik:** `.env.example` - udokumentować nowe zmienne

### 1.3 Użycie modelu

DeepSeek V3.2 integruje się przez Vercel AI SDK tak samo jak OpenAI/Anthropic:

```typescript
import { deepseek } from '@ai-sdk/deepseek';
import { generateText } from 'ai';

const result = await generateText({
  model: deepseek(env.DEEPSEEK_MODEL || 'deepseek-chat'),
  system: systemPrompt,
  messages,
  tools,
  maxSteps: 10,
});
```

**Kluczowe parametry:**
- ID modelu: `deepseek-chat` (ogólny) lub `deepseek-reasoner` (tryb rozumowania)
- Obsługuje tool use / function calling
- Okno kontekstu: 128K tokenów
- Koszt: ~$0.28/1M tokenów wejściowych (10x taniej niż Claude Sonnet)
- API kompatybilne z OpenAI pod `https://api.deepseek.com`

### 1.4 Strategia fallback

Tool calling DeepSeek może być mniej niezawodny niż Claude w scenariuszach wielokrokowych. Zabezpieczenia:
- `maxSteps: 5` (niższy niż obecne 10) dla auto-reply, żeby ograniczyć pętle
- Logika retry z exponential backoff
- Jeśli DeepSeek zawiedzie → loguj błąd i oznacz jako `needs_guidance` (bezpieczny fallback)

---

## Faza 2: Serwer MCP systemu zamówień Frami

### 2.1 Model danych Frami-Composer (źródło prawdy)

Backend Django w `~/Development/framky/frami-composer` zawiera:

**Zamówienie (Order)** - `apps/orders/models.py`:
- `number` (unikalny), `status` (0-15 cykl życia), `email`, `user`
- Wysyłka: `shipping_first_name`, `shipping_last_name`, `shipping_phone_number`, pełny adres
- Ceny: `price_final`, `currency`, kupony/vouchery
- Daty: `paid_at`, `shipping_eta`, `shipping_etd`
- Powiązania: `compositions` (M2M przez OrderComposition z quantity)

**Statusy zamówień:**
```
-1=Problem z płatnością, 0=Nowe, 1=Dane wprowadzone,
2=Płatność w toku, 3=Opłacone, 4=Gotowe do produkcji,
5=W produkcji, 6=Gotowe do wysyłki, 7=Wysłane,
8=Dostarczone, 9=Wstrzymane, 10=Anulowane,
11=Reklamacja, 12=Edycja zdjęcia, 15=Prośba o płatność
```

**Paczka/Przesyłka (Package)** - `apps/shipment/models.py`:
- `tracking_number`, `tracking_url`, `carrier` (FK do Carrier)
- `status` (-1 do 12): ZAPLANOWANA→UTWORZONA→WYSŁANA→W DRODZE→DOSTARCZONA
- `delivered_at`, wymiary, waga
- `PackageStatusHistory`: oś czasu zmian statusu z datami rzeczywistymi/oczekiwanymi
- Przewoźnicy: Apaczka (PL: DPD, InPost), GoGlobal (międzynarodowy), Paxy (zbiorczy)

**Istniejące Django REST API:**
- Autoryzacja: `Authorization: Token <token>`
- `GET /orders/` - lista zamówień (z filtrami)
- `GET /orders/{id}/` - szczegóły zamówienia z tracking_urls, timeline_data, compositions
- `GET /shipment/tracking/` - śledzenie paczek
- CORS włączony, Token + Basic auth

### 2.2 Nowy serwer MCP: `FramiOrderMCP`

**Nowy plik:** `apps/server/src/routes/agent/frami-order-mcp.ts`

Rozszerza `McpAgent` (ten sam wzorzec co `ZeroMCP` w `mcp.ts`). Komunikuje się z Django API frami-composer przez HTTP fetch.

**Narzędzia do zarejestrowania:**

| Narzędzie | Endpoint Frami API | Opis |
|-----------|--------------------|------|
| `getOrder` | `GET /orders/{id}/` | Pełne dane zamówienia ze statusem, pozycjami, informacją o wysyłce |
| `getOrdersByEmail` | `GET /orders/?email={email}` | Wszystkie zamówienia klienta po emailu |
| `getOrderTimeline` | `GET /orders/{id}/` → `timeline_data` | Historia statusów z datami |
| `getShipmentTracking` | `GET /orders/{id}/` → `tracking_urls` | URL-e śledzenia i statusy paczek |
| `searchOrders` | `GET /orders/?search={query}` | Szukaj po numerze zamówienia, nazwisku, emailu |
| `getOrderStatus` | `GET /orders/{id}/` → `status` | Szybkie sprawdzenie statusu z etykietą czytelną dla człowieka |

**Wzorzec implementacji:**
```typescript
this.server.registerTool(
  'getOrdersByEmail',
  {
    description: 'Pobierz wszystkie zamówienia klienta po adresie email',
    inputSchema: { email: z.string().email() },
  },
  async ({ email }) => {
    const response = await fetch(
      `${env.FRAMI_API_URL}/orders/?email=${encodeURIComponent(email)}`,
      { headers: { Authorization: `Token ${env.FRAMI_API_TOKEN}` } },
    );
    const orders = await response.json();
    return {
      content: orders.results.map((o: any) => ({
        type: 'text' as const,
        text: `Zamówienie #${o.number} | Status: ${statusLabel(o.status)} | Kwota: ${o.price_final} ${o.currency} | Opłacone: ${o.paid_at || 'nieopłacone'} | ETA: ${o.shipping_eta || 'brak'}`,
      })),
    };
  },
);
```

### 2.3 Helper etykiet statusów

Mapowanie numerycznych statusów na etykiety czytelne dla AI:

```typescript
const ORDER_STATUS_LABELS: Record<number, string> = {
  [-1]: 'Problem z płatnością', 0: 'Nowe', 1: 'Dane wprowadzone',
  2: 'Płatność w toku', 3: 'Opłacone', 4: 'Gotowe do produkcji',
  5: 'W produkcji', 6: 'Gotowe do wysyłki', 7: 'Wysłane',
  8: 'Dostarczone', 9: 'Wstrzymane', 10: 'Anulowane',
  11: 'Reklamacja', 12: 'Wymagana edycja zdjęcia', 15: 'Prośba o płatność',
};

const PACKAGE_STATUS_LABELS: Record<number, string> = {
  [-1]: 'Zaplanowana', 0: 'Nieznany', 1: 'Utworzona', 2: 'Wysłana',
  3: 'W hubie', 4: 'Zeskanowana przez przewoźnika', 5: 'W drodze',
  6: 'W doręczeniu', 7: 'Dostarczona', 8: 'Czeka w punkcie odbioru',
  9: 'Niedostarczona', 10: 'Zgubiona', 11: 'Anulowana', 12: 'Wymagana akcja',
};
```

### 2.4 Konfiguracja Wrangler i Env

**Plik:** `apps/server/wrangler.jsonc` - dodać binding Durable Object:
```jsonc
{ "name": "FRAMI_ORDER_MCP", "class_name": "FramiOrderMCP" }
```

**Plik:** `apps/server/src/env.ts` - dodać typ:
```typescript
FRAMI_ORDER_MCP: DurableObjectNamespace<FramiOrderMCP & QueryableHandler>;
```

**Plik:** `apps/server/src/main.ts` - wyeksportować klasę

---

## Faza 3: Baza wiedzy i model danych

### 3.1 Nowa tabela PostgreSQL: `mail0_knowledge_scenario`

**Plik:** `apps/server/src/db/schema.ts`

```typescript
export const knowledgeScenario = pgTable('mail0_knowledge_scenario', {
  id: text('id').primaryKey().$defaultFn(() => crypto.randomUUID()),
  connectionId: text('connection_id').notNull().references(() => connection.id),
  scenario: text('scenario').notNull(),        // opis scenariusza
  guidance: text('guidance').notNull(),         // jak obsługiwać
  exampleEmail: text('example_email'),          // treść maila wyzwalającego
  exampleReply: text('example_reply'),          // odpowiedź która została wysłana
  senderPattern: text('sender_pattern'),        // np. "*@klient.pl"
  keywords: text('keywords').array(),           // słowa kluczowe do dopasowania
  usageCount: integer('usage_count').default(0),
  createdAt: timestamp('created_at').defaultNow(),
  updatedAt: timestamp('updated_at').defaultNow(),
});
```

### 3.2 Nowa tabela PostgreSQL: `mail0_auto_reply_result`

```typescript
export const autoReplyResult = pgTable('mail0_auto_reply_result', {
  id: text('id').primaryKey().$defaultFn(() => crypto.randomUUID()),
  connectionId: text('connection_id').notNull().references(() => connection.id),
  threadId: text('thread_id').notNull(),
  messageId: text('message_id').notNull(),
  status: text('status').notNull(),  // 'draft_created' | 'needs_guidance' | 'skipped' | 'sent'
  confidence: real('confidence'),
  draftContent: text('draft_content'),
  questions: jsonb('questions'),     // string[]
  userGuidance: text('user_guidance'),
  scenarioId: text('scenario_id').references(() => knowledgeScenario.id),
  createdAt: timestamp('created_at').defaultNow(),
  updatedAt: timestamp('updated_at').defaultNow(),
});
```

### 3.3 Vectorize do dopasowania semantycznego (istniejąca infrastruktura)

Użycie `env.VECTORIZE` + `getEmbeddingVector()` (z `apps/server/src/routes/agent/tools.ts`) do:
- Przechowywania embeddingów tekstu `scenario + guidance` każdego scenariusza wiedzy
- Przy nowym mailu: embed treści maila i znajdź top-K pasujących scenariuszy
- Dołączenie znalezionych scenariuszy do kontekstu DeepSeek

**Fallback:** Jeśli Vectorize niedostępny → dopasowanie po tablicy `keywords` i `senderPattern` z PostgreSQL.

---

## Faza 4: Serwis automatycznych odpowiedzi

### 4.1 Główny analizator

**Nowy plik:** `apps/server/src/services/auto-reply-service.ts`

```typescript
import { deepseek } from '@ai-sdk/deepseek';
import { generateObject } from 'ai';
import { z } from 'zod';

const AutoReplyDecisionSchema = z.object({
  confidence: z.number().min(0).max(1),
  action: z.enum(['draft', 'ask_user', 'skip']),
  draftContent: z.string().optional(),
  questions: z.array(z.string()).optional(),
  reasoning: z.string(),
});

type AutoReplyDecision = z.infer<typeof AutoReplyDecisionSchema>;

export async function analyzeEmail(params: {
  threadId: string;
  messageId: string;
  connectionId: string;
  emailContent: string;
  senderEmail: string;
  subject: string;
}): Promise<AutoReplyDecision> {
  // 1. Załaduj scenariusze wiedzy (PostgreSQL + Vectorize)
  // 2. Załaduj poprzednie wątki nadawcy (przez ZeroMCP listThreads)
  // 3. Załaduj dane zamówień nadawcy (przez FramiOrderMCP getOrdersByEmail)
  // 4. Załaduj macierz stylu pisania
  // 5. Wywołaj DeepSeek z całym kontekstem + narzędziami
  // 6. Zwróć ustrukturyzowaną decyzję
}
```

**Struktura system promptu:**
```
Jesteś asystentem email dla firmy zajmującej się oprawą obrazów (Frami).
Masz dostęp do systemu zamówień i historii maili.

Twoje zadanie:
1. Przeczytaj przychodzącego maila
2. Oceń czy potrafisz pewnie odpowiedzieć
3. Jeśli TAK (pewność > 0.7): Napisz profesjonalną odpowiedź używając danych zamówienia klienta
4. Jeśli NIEPEWNIE (0.3-0.7): Napisz draft odpowiedzi I wymień pytania do zweryfikowania przez właściciela
5. Jeśli NIE (< 0.3): Wymień konkretne pytania które musisz znać żeby odpowiedzieć

Dostępny kontekst:
- Historia zamówień klienta (narzędzie getOrdersByEmail)
- Śledzenie przesyłek (narzędzie getShipmentTracking)
- Poprzednie wątki email od tego nadawcy
- Baza wiedzy z dotychczasowymi scenariuszami obsługi

Styl pisania: [WritingStyleMatrix]
Znane scenariusze: [dopasowane scenariusze wiedzy]
```

### 4.2 Serwis bazy wiedzy

**Nowy plik:** `apps/server/src/services/knowledge-service.ts`

```typescript
export async function findMatchingScenarios(connectionId: string, emailContent: string);
export async function createScenario(connectionId: string, data: NewScenario);
export async function learnFromInteraction(params: {
  connectionId: string;
  emailContent: string;
  replyContent: string;
  userGuidance?: string;
  senderEmail: string;
});
```

### 4.3 Integracja z synchronizacją maili

**Plik:** `apps/server/src/routes/agent/index.ts` (metoda `syncThread()` w ZeroDriver)

Po zsynchronizowaniu nowego maila w INBOX:
1. Sprawdź: czy INBOX? czy nieprzeczytany? czy NIE od użytkownika?
2. `ctx.waitUntil(analyzeEmail(...))` - nieblokujące
3. Zapisz wynik do tabeli `auto_reply_result`
4. Jeśli `action === 'draft'`: utwórz draft przez istniejący flow `createDraft()`
5. Wyślij aktualizację do frontendu przez WebSocket (istniejący wzorzec)

---

## Faza 5: Integracja frontendowa

### 5.1 Komponent bannera auto-reply

**Nowy plik:** `apps/mail/components/mail/auto-reply-banner.tsx`

Wyświetlany w `mail-display.tsx` gdy istnieje `auto_reply_result` dla bieżącego wątku:

**Stan `needs_guidance`:**
```
┌──────────────────────────────────────────────────┐
│ 🤖 AI potrzebuje wskazówki, żeby odpowiedzieć    │
│                                                    │
│ • Czy klient ma prawo do zwrotu po 30 dniach?     │
│ • Czy zaoferować wymianę czy zwrot pieniędzy?     │
│                                                    │
│ [Twoja wskazówka...]                               │
│                                                    │
│ [Wygeneruj odpowiedź]  [Pomiń]                    │
└──────────────────────────────────────────────────┘
```

**Stan `draft_created`:**
```
┌──────────────────────────────────────────────────┐
│ ✅ AI wygenerowało szkic odpowiedzi (pewność 85%) │
│ [Zobacz szkic]  [Pomiń]                           │
└──────────────────────────────────────────────────┘
```

Po udzieleniu wskazówki przez użytkownika:
1. Wywołaj ponownie serwis auto-reply ze wskazówką
2. Utwórz draft z wygenerowaną odpowiedzią
3. Zapisz scenariusz do bazy wiedzy na przyszłość

### 5.2 Ręczne wyzwalanie: przycisk "AI Reply"

**Plik:** `apps/mail/components/mail/mail-display.tsx`

Dodaj przycisk obok Reply/ReplyAll/Forward na pasku akcji wątku. Wyzwala mutację `autoReply.triggerAnalysis` tRPC.

### 5.3 Nowe trasy tRPC

**Nowy plik:** `apps/server/src/trpc/routes/auto-reply.ts`

```typescript
autoReply.getResult({ threadId })                // Pobierz wynik analizy dla wątku
autoReply.submitGuidance({ threadId, guidance })  // Wyślij wskazówkę → re-analiza → utwórz draft
autoReply.triggerAnalysis({ threadId })            // Ręczne wyzwalanie
autoReply.listKnowledge({ connectionId })          // Lista nauczonych scenariuszy
autoReply.deleteKnowledge({ id })                  // Usuń scenariusz
```

**Plik:** `apps/server/src/trpc/router.ts` - zarejestruj router `autoReply`

### 5.4 React Hook

**Nowy plik:** `apps/mail/hooks/use-auto-reply.ts`

```typescript
export function useAutoReply(threadId: string) {
  // Zapytanie o auto_reply_result dla tego wątku
  // Mutacja submitGuidance
  // Mutacja triggerAnalysis
}
```

---

## Faza 6: Rejestracja MCP i podpięcie

### 6.1 Rejestracja FramiOrderMCP w ZeroAgent

**Plik:** `apps/server/src/routes/agent/index.ts`

Dodaj `registerFramiOrderMCP()` według wzorca `registerZeroMCP()` (ok. linii 1703):
```typescript
async registerFramiOrderMCP() {
  await this.mcp.connect(this.env.VITE_PUBLIC_BACKEND_URL + '/frami-order/sse', {
    transport: {
      authProvider: new DurableObjectOAuthClientProvider({ ... })
    }
  });
}
```

Wywołaj z `onStart()` obok istniejących rejestracji MCP.

### 6.2 Eksport w Main

**Plik:** `apps/server/src/main.ts` - wyeksportuj `FramiOrderMCP`

### 6.3 Trasa Hono

**Plik:** `apps/server/src/main.ts` lub plik tras - dodaj endpoint SSE dla FramiOrderMCP

---

## Pliki do modyfikacji

| Plik | Zmiany |
|------|--------|
| `apps/server/src/db/schema.ts` | Dodaj tabele `knowledgeScenario` + `autoReplyResult` |
| `apps/server/src/env.ts` | Dodaj `DEEPSEEK_API_KEY`, `FRAMI_API_*`, `FRAMI_ORDER_MCP` |
| `apps/server/wrangler.jsonc` | Dodaj binding DO dla `FramiOrderMCP`, zmienne środowiskowe |
| `apps/server/src/main.ts` | Wyeksportuj `FramiOrderMCP`, dodaj trasę SSE |
| `apps/server/src/routes/agent/index.ts` | `registerFramiOrderMCP()`, podpięcie auto-reply do sync |
| `apps/server/src/trpc/router.ts` | Dodaj router `autoReply` |
| `apps/mail/components/mail/mail-display.tsx` | Dodaj banner auto-reply + przycisk AI Reply |
| `apps/server/package.json` | Dodaj zależność `@ai-sdk/deepseek` |

## Nowe pliki do utworzenia

| Plik | Cel |
|------|-----|
| `apps/server/src/routes/agent/frami-order-mcp.ts` | FramiOrderMCP - serwer MCP proxy do Django API frami-composer |
| `apps/server/src/services/auto-reply-service.ts` | Główna orkiestracja auto-reply z DeepSeek V3.2 |
| `apps/server/src/services/knowledge-service.ts` | CRUD bazy wiedzy i dopasowanie semantyczne |
| `apps/server/src/trpc/routes/auto-reply.ts` | Trasy tRPC dla UI auto-reply |
| `apps/mail/components/mail/auto-reply-banner.tsx` | Komponent UI bannera z pytaniami AI / statusem draftu |
| `apps/mail/hooks/use-auto-reply.ts` | React hook do stanu auto-reply |

## Istniejące funkcje do ponownego wykorzystania

| Funkcja/Wzorzec | Lokalizacja | Zastosowanie |
|-----------------|-------------|--------------|
| `composeEmail()` | `apps/server/src/trpc/routes/ai/compose.ts` | Wzorzec generowania odpowiedzi ze stylem pisania |
| `getWritingStyleMatrixForConnectionId()` | `apps/server/src/services/writing-style-service.ts` | Styl pisania użytkownika |
| `StyledEmailAssistantSystemPrompt()` | `apps/server/src/lib/prompts.ts` | Szablon system promptu |
| `getThread()` / `getZeroAgent()` | `apps/server/src/lib/server-utils.ts` | Pobieranie danych wątku |
| `McpAgent` klasa | `apps/server/src/routes/agent/mcp.ts` | Wzorzec dla FramiOrderMCP |
| `createDraft()` flow | `apps/server/src/trpc/routes/drafts.ts` | Tworzenie draftów odpowiedzi |
| `getEmbeddingVector()` | `apps/server/src/routes/agent/tools.ts` | Embeddingi do wyszukiwania wiedzy |
| `processToolCalls()` | `apps/server/src/routes/agent/utils.ts` | Wzorzec human-in-the-loop |
| `activeConnectionProcedure` | `apps/server/src/trpc/trpc.ts` | Middleware auth dla tras tRPC |
| `syncThread()` | `apps/server/src/routes/agent/index.ts` | Punkt podpięcia auto-analizy |

---

## Plan weryfikacji

### Testy jednostkowe
- `auto-reply-service.test.ts` - Test z mockowanymi odpowiedziami DeepSeek
- `knowledge-service.test.ts` - Test CRUD scenariuszy i dopasowania
- `frami-order-mcp.test.ts` - Test narzędzi MCP z mockowanym API Frami

### Testy integracyjne
- Synchronizacja nowego maila → weryfikacja utworzenia `auto_reply_result`
- Wysłanie wskazówki → weryfikacja utworzenia draftu + zapisania scenariusza
- Przyjście podobnego maila → weryfikacja dopasowania istniejącego scenariusza

### Manualny test E2E
1. Skonfiguruj `DEEPSEEK_API_KEY` oraz `FRAMI_API_URL`/`FRAMI_API_TOKEN`
2. Uruchom serwery dev: `pnpm go` (Zero) + serwer Django frami-composer
3. Odbierz nowego maila od klienta z istniejącym zamówieniem
4. Zweryfikuj wykonanie analizy auto-reply (sprawdź DB `auto_reply_result`)
5. Otwórz maila → zobacz banner z draftem lub pytaniami
6. Udziel wskazówki → zweryfikuj wygenerowanie draftu
7. Wyślij odpowiedź → zweryfikuj zapisanie scenariusza wiedzy
8. Odbierz podobnego maila → zweryfikuj poprawę auto-reply

### Test MCP
- Otwórz AI chat sidebar → zapytaj "Jakie zamówienia ma klient@example.com?"
- Zweryfikuj czy FramiOrderMCP zwraca prawdziwe dane z frami-composer

---

## Kolejność implementacji

1. **Faza 1** - Setup providera DeepSeek V3.2 + konfiguracja env
2. **Faza 2** - FramiOrderMCP (łączy się z prawdziwym API frami-composer)
3. **Faza 3** - Tabele bazy wiedzy + migracja
4. **Faza 4** - Serwis auto-reply + serwis wiedzy
5. **Faza 5** - Frontend: banner, przycisk, trasy tRPC, hook
6. **Faza 6** - Podpięcie MCP do agenta, wpięcie w sync

Każda faza jest testowalnie niezależna. Faza 2 może być zweryfikowana natychmiast przez AI chat sidebar.
