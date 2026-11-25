#ifndef TREE_SITTER_YAML_H_
#define TREE_SITTER_YAML_H_

typedef struct TSLanguage TSLanguage;

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *tree_sitter_yaml(void);

// Plainsong: the external scanner's state functions, declared so a test can check
// the serialization bound without relying on tree-sitter's assertion.
void *tree_sitter_yaml_external_scanner_create(void);
void tree_sitter_yaml_external_scanner_destroy(void *payload);
unsigned tree_sitter_yaml_external_scanner_serialize(void *payload, char *buffer);
void tree_sitter_yaml_external_scanner_deserialize(void *payload, const char *buffer, unsigned length);

#ifdef __cplusplus
}
#endif

#endif // TREE_SITTER_YAML_H_
