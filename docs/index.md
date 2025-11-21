---
# Empty Jekyll front matter to enable Liquid templating (see {{ ... }} below)
---

{% for version in site.data.versions -%}
- [v{{ version }}](https://rubydoc.info/gems/mcp/{{ version }})
{% endfor %}
