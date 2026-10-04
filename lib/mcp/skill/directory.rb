# frozen_string_literal: true

require "digest"

module MCP
  class Skill
    # Directory-backed skills (SEP-2640): `from_directory` turns every directory under a root that holds
    # a `SKILL.md` into a skill whose files the server's default `resources/read` serves, with the digests and
    # sizes computed here.
    #
    # Rules fixed for the first release: regular files only (symbolic links, FIFOs, sockets, and devices are
    # skipped, hard links refused), dotfiles skipped, everything else published (editor backups included), every directory and file
    # name limited to the unreserved URI characters, a directory holding its own `SKILL.md` a skill of its own
    # whose files the enclosing skill lists as supporting files too, files read at request time and refused
    # with one generic error when they changed since registration.
    class << self
      # Scans `root` and returns the skills found under it (an Array of `MCP::Skill`, ordered by URI); every
      # problem is an `ArgumentError` naming the path. `root` is resolved once with `File.realpath`, so
      # a symbolic link to the directory is fine; a `SKILL.md` directly under `root`, or no skill at all, is
      # refused, because `root` is the container of skill directories, not a skill.
      #
      # The tree is trusted as the operator's: it must be writable only by the operator while skills are built
      # and served. The checks on each file narrow what a concurrent change to the tree can do; they do not
      # confine a writer who can change it.
      def from_directory(root)
        root = root.to_path if root.respond_to?(:to_path)
        raise ArgumentError, "The skills root must be a path String (got #{root.class})." unless root.is_a?(String)

        real_root = begin
          File.realpath(root)
        rescue SystemCallError => e
          raise ArgumentError, "The skills root #{root} cannot be resolved (#{e.class})."
        end
        raise ArgumentError, "The skills root #{real_root} is not a directory." unless File.directory?(real_root)
        if File.exist?(File.join(real_root, Uri::MANIFEST))
          raise ArgumentError, "The skills root #{real_root} holds a SKILL.md itself; pass the directory that contains the skill directories."
        end

        skills = []
        scan_directory(real_root, [], skills)
        raise ArgumentError, "No directory holding a SKILL.md was found under #{real_root}." if skills.empty?

        skills.sort_by(&:uri)
      end

      # Serves one file of a directory-backed skill for a custom `resources_read_handler`, which replaces
      # the default reader and with it the serving of skill files: returns the `contents` Array holding one item,
      # or nil when `uri` is not a file of any of `skills`. A file that changed since registration raises
      # the same `-32603` the default reader answers. The files of a nested skill are files of the enclosing skill
      # as well, so a caller given the enclosing skill reads them whether or not the nested one is among `skills`.
      def read_file(skills, uri)
        record = file_map(skills)[uri]
        return unless record

        [read_record_item(record)]
      rescue FileError => e
        raise file_changed_error(nil, e)
      end

      # The default reader's path for a file record found in the server's map.
      #
      # @api private
      def read_record(record, request)
        [read_record_item(record)]
      rescue FileError => e
        raise file_changed_error(request, e)
      end

      private

      # Internal: a file could not be read as registered; the message names the path and is reported only.
      class FileError < StandardError; end

      # Frozen through, so a custom reader handed `read_file`'s item cannot alter the URI later responses carry.
      FileRecord = Struct.new(:uri, :path, :size, :digest, :dev, :ino, :text, keyword_init: true) do
        def initialize(**kwargs)
          super(**kwargs)
          each { |member| member.freeze if member.is_a?(String) }
          freeze
        end
      end

      MIME_TYPES = { ".md" => "text/markdown" }.freeze

      def scan_directory(directory, segments, skills)
        children_of(directory).each do |name|
          next if name.start_with?(".")

          path = File.join(directory, name)
          next unless lstat_of(path).directory?

          check_name!(name, path)
          child_segments = segments + [name]
          if skill_directory?(path)
            skills << collect_skill(path, child_segments, skills)
          else
            scan_directory(path, child_segments, skills)
          end
        end
      end

      def skill_directory?(path)
        File.lstat(File.join(path, Uri::MANIFEST)).file?
      rescue SystemCallError
        false
      end

      def check_name!(name, path)
        return if Uri::LOCAL_SEGMENT.match?(name)

        raise ArgumentError, "The name of #{path} may only use letters, digits, -, ., _, and ~, so that it can be a skill:// URI segment."
      end

      # Directory listing and `lstat` in a stable order; a filesystem error is reported as an `ArgumentError`
      # like every other construction problem, since the input is the operator's own tree.
      def children_of(directory)
        Dir.children(directory).sort
      rescue SystemCallError => e
        raise ArgumentError, "The directory #{directory} cannot be listed (#{e.class})."
      end

      def lstat_of(path)
        File.lstat(path)
      rescue SystemCallError => e
        raise ArgumentError, "The entry #{path} cannot be examined (#{e.class})."
      end

      # Builds the skill rooted at `directory`: walks its files, reads the frontmatter from the same bytes
      # the manifest's digest was computed over, and attaches the file records.
      def collect_skill(directory, segments, skills)
        root_uri = Uri.root(segments)
        manifest_uri = "#{root_uri}/#{Uri::MANIFEST}"
        walk = { records: {}, manifest_uri: manifest_uri, manifest_bytes: nil, budget: MAX_TOTAL_SIZE }
        walk_skill_files(directory, segments, walk, skills)

        records = walk[:records].sort_by { |uri, _record| uri }.to_h
        manifest_bytes = walk[:manifest_bytes]
        # `skill_directory?` saw the file, so only a change to the tree during the scan leaves it unread.
        raise ArgumentError, "The SKILL.md of #{directory} disappeared while the directory was being scanned." if manifest_bytes.nil?

        frontmatter = begin
          Frontmatter.load(manifest_bytes)
        rescue Frontmatter::Error => e
          raise ArgumentError, "The frontmatter of #{records.fetch(manifest_uri).path} cannot be read (#{e.reason}); see the frontmatter rules in the Skills documentation."
        end

        entries = records.values.map { |record| ResourceEntry.new(uri: record.uri, digest: record.digest, size: record.size) }
        begin
          with_file_records(uri: manifest_uri, frontmatter: frontmatter, resources: entries, file_records: records.freeze)
        rescue ArgumentError => e
          raise ArgumentError, "#{directory}: #{e.message}"
        end
      end

      def walk_skill_files(directory, segments, walk, skills)
        children_of(directory).each do |name|
          next if name.start_with?(".")

          path = File.join(directory, name)
          stat = lstat_of(path)
          next unless stat.directory? || stat.file?

          check_name!(name, path)
          child_segments = segments + [name]
          if stat.directory?
            if skill_directory?(path)
              # A nested skill is published on its own, and its files are supporting files of the enclosing
              # skill as well: the records are shared, so both manifests carry the same digests and sizes.
              nested = collect_skill(path, child_segments, skills)
              skills << nested
              adopt_records(nested.__send__(:file_records), walk)
            else
              walk_skill_files(path, child_segments, walk, skills)
            end
          else
            uri = Uri.root(child_segments)
            record, bytes = capture_file(path, uri, walk)
            walk[:records][uri] = record
            walk[:manifest_bytes] = bytes if uri == walk[:manifest_uri]
          end
        end
      end

      # Adds a nested skill's records to the enclosing skill's walk; they count against its size budget like
      # its own files, since the specification counts the limits over every listed entry.
      def adopt_records(records, walk)
        records.each_value do |record|
          if record.size > walk[:budget]
            raise ArgumentError, "#{record.path} takes the enclosing skill past the #{MAX_TOTAL_SIZE} byte limit of SEP-2640"
          end

          walk[:budget] -= record.size
          walk[:records][record.uri] = record
        end
      end

      # Hashes one file and returns its record with the bytes it hashed. The skill's remaining size budget is
      # checked against `fstat` before anything is read, so an oversized file is refused without loading it, and
      # the read itself stops one byte past the budget, so a file growing after that check is never held whole.
      def capture_file(path, uri, walk)
        # The paths come from the resolved root, so `realpath` must return the path unchanged; an intermediate
        # directory swapped for a symbolic link after `lstat` breaks that. Checked before and after the open,
        # so passing takes two swaps inside that window instead of one.
        raise FileError, "#{path} is not the file its path names" unless resolved_path?(path)

        open_regular_file(path) do |io, stat|
          # A hard link reaches a file outside the tree the way a symbolic link would, so it is refused rather than
          # skipped, which tells the operator that a file is missing from the manifest. The handle must also be
          # the file its path names now.
          raise FileError, "#{path} has more than one hard link" if stat.nlink > 1

          current = File.stat(path)
          unless resolved_path?(path) && current.dev == stat.dev && current.ino == stat.ino
            raise FileError, "#{path} is not the file its path names"
          end

          if stat.size > walk[:budget]
            raise FileError, "#{path} takes the skill past the #{MAX_TOTAL_SIZE} byte limit of SEP-2640"
          end

          bytes = io.read(walk[:budget] + 1) || "".b
          if bytes.bytesize > walk[:budget]
            raise FileError, "#{path} takes the skill past the #{MAX_TOTAL_SIZE} byte limit of SEP-2640"
          end

          walk[:budget] -= bytes.bytesize
          record = FileRecord.new(
            uri: uri,
            path: path,
            size: bytes.bytesize,
            digest: "sha256:#{Digest::SHA256.hexdigest(bytes)}",
            dev: stat.dev,
            ino: stat.ino,
            text: bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?,
          )
          [record, bytes]
        end
      rescue FileError => e
        raise ArgumentError, e.message
      end

      def resolved_path?(path)
        File.realpath(path) == path
      rescue SystemCallError
        false
      end

      # Opens a regular file for reading without following a symbolic link in its last component, and hands
      # the handle and its `fstat` to the block; everything the block reads comes from the handle it checked.
      # Where the platform lacks `NOFOLLOW`, an `lstat` before the open refuses a symbolic link instead;
      # the `fstat` comparison and the digest over the served bytes still close the race.
      def open_regular_file(path)
        if !nofollow_supported? && File.lstat(path).symlink?
          raise FileError, "#{path} is a symbolic link"
        end

        File.open(path, open_flags) do |io|
          io.binmode
          stat = io.stat
          raise FileError, "#{path} is not a regular file" unless stat.file?

          yield io, stat
        end
      rescue SystemCallError, IOError => e
        raise FileError, "#{path} cannot be read (#{e.class})"
      end

      def open_flags
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if nofollow_supported?
        flags
      end

      def nofollow_supported?
        File::Constants.const_defined?(:NOFOLLOW)
      end

      # Reads a registered file for serving: the handle must still be the recorded inode with the recorded size
      # and no additional hard link (`nlink` is compared the way registration does, so a filesystem that reports 0
      # is served), and the bytes read (at most one more than recorded, so growth shows) must still have
      # the recorded digest.
      def read_record_item(record)
        open_regular_file(record.path) do |io, stat|
          unless stat.size == record.size && stat.dev == record.dev && stat.ino == record.ino && stat.nlink <= 1
            raise FileError, "#{record.path} changed since registration (inode, size, or link count)"
          end

          data = io.read(record.size + 1) || "".b
          unless data.bytesize == record.size && "sha256:#{Digest::SHA256.hexdigest(data)}" == record.digest
            raise FileError, "#{record.path} changed since registration (content)"
          end

          item = { uri: record.uri }
          mime_type = MIME_TYPES[File.extname(record.path)]
          item[:mimeType] = mime_type if mime_type
          if record.text
            item[:text] = data.force_encoding(Encoding::UTF_8)
          else
            item[:blob] = [data].pack("m0")
          end
          item
        end
      end

      def file_changed_error(request, cause)
        Server::RequestHandlerError.new(
          "Skill file changed since registration",
          request,
          error_type: :internal_error,
          error_code: JsonRpcHandler::ErrorCode::INTERNAL_ERROR,
          original_error: cause,
        )
      end
    end
  end
end
