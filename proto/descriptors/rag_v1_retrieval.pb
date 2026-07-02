
Þ
rag/v1/retrieval.protorag.v1"»
DocumentChunk
id (	Rid

repository (	R
repository
path (	Rpath
language (	Rlanguage

start_line (R	startLine
end_line (RendLine
text (	Rtext?
metadata (2#.rag.v1.DocumentChunk.MetadataEntryRmetadata;
MetadataEntry
key (	Rkey
value (	Rvalue:8"C
IndexChunksRequest-
chunks (2.rag.v1.DocumentChunkRchunks";
Vector
chunk_id (	RchunkId
values (Rvalues"?
IndexVectorsRequest(
vectors (2.rag.v1.VectorRvectors"Ò
SearchRequest
query (	Rquery
	embedding (R	embedding
top_k (RtopK<
filters (2".rag.v1.SearchRequest.FiltersEntryRfilters:
FiltersEntry
key (	Rkey
value (	Rvalue:8"k
SearchResult
chunk_id (	RchunkId
score (Rscore
rank (Rrank
source (	Rsource"@
SearchResponse.
results (2.rag.v1.SearchResultRresults"À
HybridSearchRequest
query (	Rquery
top_k (RtopKB
filters (2(.rag.v1.HybridSearchRequest.FiltersEntryRfilters:
FiltersEntry
key (	Rkey
value (	Rvalue:8"E
HybridSearchResponse-
chunks (2.rag.v1.DocumentChunkRchunks"À
RerankCandidate
chunk_id (	RchunkId
text (	RtextA
metadata (2%.rag.v1.RerankCandidate.MetadataEntryRmetadata;
MetadataEntry
key (	Rkey
value (	Rvalue:8"^
RerankRequest
query (	Rquery7

candidates (2.rag.v1.RerankCandidateR
candidates"S
RerankResult
chunk_id (	RchunkId
score (Rscore
rank (Rrank"@
RerankResponse.
results (2.rag.v1.RerankResultRresults"
HealthRequest"£
HealthResponse
status (	Rstatus=
details (2#.rag.v1.HealthResponse.DetailsEntryRdetails:
DetailsEntry
key (	Rkey
value (	Rvalue:82Ê
DenseIndexService7
Health.rag.v1.HealthRequest.rag.v1.HealthResponseC
IndexVectors.rag.v1.IndexVectorsRequest.rag.v1.HealthResponse7
Search.rag.v1.SearchRequest.rag.v1.SearchResponse2Ê
LexicalIndexService7
Health.rag.v1.HealthRequest.rag.v1.HealthResponseA
IndexChunks.rag.v1.IndexChunksRequest.rag.v1.HealthResponse7
Search.rag.v1.SearchRequest.rag.v1.SearchResponse2ƒ
RerankerService7
Health.rag.v1.HealthRequest.rag.v1.HealthResponse7
Rerank.rag.v1.RerankRequest.rag.v1.RerankResponse2“
HybridSearchService7
Health.rag.v1.HealthRequest.rag.v1.HealthResponseC
Search.rag.v1.HybridSearchRequest.rag.v1.HybridSearchResponsebproto3