require "digest/sha1"
require "pathname"
require "tempfile"
require "tmpdir"
require "webrick"

require File.expand_path("../../../../base", __FILE__)

require "vagrant/util/file_checksum"

describe Vagrant::Action::Builtin::BoxAdd do
  include_context "unit"

  let(:app) { lambda { |env| } }
  let(:env) { {
    box_collection: box_collection,
    tmp_path: Pathname.new(Dir.mktmpdir),
    ui: Vagrant::UI::Silent.new,
  } }

  subject { described_class.new(app, env) }

  let(:box_collection) { double("box_collection") }
  let(:iso_env) { isolated_environment }

  let(:box) do
    box_dir = iso_env.box3("foo", "1.0", :virtualbox)
    Vagrant::Box.new("foo", :virtualbox, "1.0", box_dir)
  end

  # Helper to quickly SHA1 checksum a path
  def checksum(path)
    FileChecksum.new(path, Digest::SHA1).checksum
  end

  def with_web_server(path)
    tf = Tempfile.new("vagrant")
    tf.close

    mime_types = WEBrick::HTTPUtils::DefaultMimeTypes
    mime_types.store "json", "application/json"

    port   = 3838
    server = WEBrick::HTTPServer.new(
      AccessLog: [],
      Logger: WEBrick::Log.new(tf.path, 7),
      Port: port,
      DocumentRoot: path.dirname.to_s,
      MimeTypes: mime_types)
    thr = Thread.new { server.start }
    yield port
  ensure
    server.shutdown rescue nil
    thr.join rescue nil
  end

  before do
    box_collection.stub(find: nil)
  end

  context "with box file directly" do
    it "adds it" do
      box_path = iso_env.box2_file(:virtualbox)

      env[:box_name] = "foo"
      env[:box_url] = box_path.to_s

      box_collection.should_receive(:add).with do |path, name, version|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo")
        expect(version).to eq("0")
        true
      end.and_return(box)

      app.should_receive(:call).with(env)

      subject.call(env)
    end

    it "adds from HTTP URL" do
      box_path = iso_env.box2_file(:virtualbox)
      with_web_server(box_path) do |port|
        env[:box_name] = "foo"
        env[:box_url] = "http://127.0.0.1:#{port}/#{box_path.basename}"

        box_collection.should_receive(:add).with do |path, name, version|
          expect(checksum(path)).to eq(checksum(box_path))
          expect(name).to eq("foo")
          expect(version).to eq("0")
          true
        end.and_return(box)

        app.should_receive(:call).with(env)

        subject.call(env)
      end
    end

    it "raises an error if no name is given" do
      box_path = iso_env.box2_file(:virtualbox)

      env[:box_url] = box_path.to_s

      box_collection.should_receive(:add).never
      app.should_receive(:call).never

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::BoxAddNameRequired)
    end

    it "raises an error if the box already exists" do
      box_path = iso_env.box2_file(:virtualbox)

      env[:box_name] = "foo"
      env[:box_url] = box_path.to_s
      env[:box_provider] = "virtualbox"

      box_collection.should_receive(:find).with(
        "foo", ["virtualbox"], "0").and_return(box)
      box_collection.should_receive(:add).never
      app.should_receive(:call).never

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::BoxAlreadyExists)
    end

    it "force adds if exists and specified" do
      box_path = iso_env.box2_file(:virtualbox)

      env[:box_force] = true
      env[:box_name] = "foo"
      env[:box_url] = box_path.to_s
      env[:box_provider] = "virtualbox"

      box_collection.stub(find: box)
      box_collection.should_receive(:add).with do |path, name, version|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo")
        expect(version).to eq("0")
        true
      end.and_return(box)
      app.should_receive(:call).with(env).once

      subject.call(env)
    end
  end

  context "with box metadata" do
    it "adds from HTTP URL" do
      box_path = iso_env.box2_file(:virtualbox)
      tf = Tempfile.new(["vagrant", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end


      md_path = Pathname.new(tf.path)
      with_web_server(md_path) do |port|
        env[:box_url] = "http://127.0.0.1:#{port}/#{md_path.basename}"

        box_collection.should_receive(:add).with do |path, name, version|
          expect(name).to eq("foo/bar")
          expect(version).to eq("0.7")
          expect(checksum(path)).to eq(checksum(box_path))
          true
        end.and_return(box)

        app.should_receive(:call).with(env)

        subject.call(env)
      end
    end

    it "adds the latest version of a box with only one provider" do
      box_path = iso_env.box2_file(:virtualbox)
      tf = Tempfile.new("vagrant").tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      box_collection.should_receive(:add).with do |path, name, version|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo/bar")
        expect(version).to eq("0.7")
        true
      end.and_return(box)

      app.should_receive(:call).with(env)

      subject.call(env)
    end

    it "adds the latest version of a box with the specified provider" do
      box_path = iso_env.box2_file(:vmware)
      tf = Tempfile.new("vagrant").tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{iso_env.box2_file(:virtualbox)}"
                },
                {
                  "name": "vmware",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      env[:box_provider] = "vmware"
      box_collection.should_receive(:add).with do |path, name, version|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo/bar")
        expect(version).to eq("0.7")
        true
      end.and_return(box)

      app.should_receive(:call).with(env)

      subject.call(env)

      expect(env[:box_added]).to equal(box)
    end

    it "adds the latest version of a box with the specified provider, even if not latest" do
      box_path = iso_env.box2_file(:vmware)
      tf = Tempfile.new("vagrant").tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{iso_env.box2_file(:virtualbox)}"
                },
                {
                  "name": "vmware",
                  "url":  "#{box_path}"
                }
              ]
            },
            {
              "version": "1.5"
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      env[:box_provider] = "vmware"
      box_collection.should_receive(:add).with do |path, name, version|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo/bar")
        expect(version).to eq("0.7")
        true
      end.and_return(box)

      app.should_receive(:call).with(env)

      subject.call(env)

      expect(env[:box_added]).to equal(box)
    end

    it "adds the constrained version of a box with the only provider" do
      box_path = iso_env.box2_file(:vmware)
      tf = Tempfile.new("vagrant").tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5",
              "providers": [
                {
                  "name": "vmware",
                  "url":  "#{box_path}"
                }
              ]
            },
            { "version": "1.1" }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      env[:box_version] = "~> 0.1"
      box_collection.should_receive(:add).with do |path, name, version|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo/bar")
        expect(version).to eq("0.5")
        true
      end.and_return(box)

      app.should_receive(:call).with(env)

      subject.call(env)

      expect(env[:box_added]).to equal(box)
    end

    it "adds the constrained version of a box with the specified provider" do
      box_path = iso_env.box2_file(:vmware)
      tf = Tempfile.new("vagrant").tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5",
              "providers": [
                {
                  "name": "vmware",
                  "url":  "#{box_path}"
                },
                {
                  "name": "virtualbox",
                  "url":  "#{iso_env.box2_file(:virtualbox)}"
                }
              ]
            },
            { "version": "1.1" }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      env[:box_provider] = "vmware"
      env[:box_version] = "~> 0.1"
      box_collection.should_receive(:add).with do |path, name, version|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo/bar")
        expect(version).to eq("0.5")
        true
      end.and_return(box)

      app.should_receive(:call).with(env)

      subject.call(env)

      expect(env[:box_added]).to equal(box)
    end

    it "adds the latest version of a box with any specified provider" do
      box_path = iso_env.box2_file(:vmware)
      tf = Tempfile.new("vagrant").tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{iso_env.box2_file(:virtualbox)}"
                }
              ]
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "vmware",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      env[:box_provider] = ["virtualbox", "vmware"]
      box_collection.should_receive(:add).with do |path, name, version|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo/bar")
        expect(version).to eq("0.7")
        true
      end.and_return(box)

      app.should_receive(:call).with(env)

      subject.call(env)

      expect(env[:box_added]).to equal(box)
    end

    it "asks the user what provider if multiple options" do
      box_path = iso_env.box2_file(:virtualbox)
      tf = Tempfile.new("vagrant").tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}"
                },
                {
                  "name": "vmware",
                  "url":  "#{iso_env.box2_file(:vmware)}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path

      env[:ui].should_receive(:ask).and_return("1")

      box_collection.should_receive(:add).with do |path, name, version|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo/bar")
        expect(version).to eq("0.7")
        true
      end.and_return(box)

      app.should_receive(:call).with(env)

      subject.call(env)
    end

    it "raises an exception if no matching version" do
      box_path = iso_env.box2_file(:vmware)
      tf = Tempfile.new("vagrant").tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5",
              "providers": [
                {
                  "name": "vmware",
                  "url":  "#{box_path}"
                }
              ]
            },
            { "version": "1.1" }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      env[:box_version] = "~> 2.0"
      box_collection.should_receive(:add).never
      app.should_receive(:call).never

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::BoxAddNoMatchingVersion)
    end

    it "raises an error if there is no matching provider" do
      tf = Tempfile.new("vagrant").tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{iso_env.box2_file(:virtualbox)}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      env[:box_provider] = "vmware"
      box_collection.should_receive(:add).never
      app.should_receive(:call).never

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::BoxAddNoMatchingProvider)
    end

    it "raises an error if a box already exists" do
      box_path = iso_env.box2_file(:virtualbox)
      tf = Tempfile.new("vagrant").tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      box_collection.should_receive(:find).
        with("foo/bar", "virtualbox", "0.7").and_return(box)
      box_collection.should_receive(:add).never
      app.should_receive(:call).never

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::BoxAlreadyExists)
    end

    it "force adds a box if specified" do
      box_path = iso_env.box2_file(:virtualbox)
      tf = Tempfile.new("vagrant").tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_force] = true
      env[:box_url] = tf.path
      box_collection.stub(find: box)
      box_collection.should_receive(:add).with do |path, name, version, **opts|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo/bar")
        expect(version).to eq("0.7")
        expect(opts[:force]).to be_true
        true
      end.and_return(box)

      app.should_receive(:call).with(env)

      subject.call(env)

      expect(env[:box_added]).to equal(box)
    end
  end
end
